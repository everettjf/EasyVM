//
//  VMOSHelper.swift
//  EZVM
//
//  Created by everettjf on 2022/10/1.
//

import Foundation
import CryptoKit
import Security
import Virtualization

enum VMHostCapability: String, CaseIterable, Identifiable {
    case virtualization
    case vmnet
    case accessoryAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .virtualization: "Virtualization"
        case .vmnet: "VMNet"
        case .accessoryAccess: "Accessory Access"
        }
    }

    var entitlementKeys: [String] {
        switch self {
        case .virtualization:
            ["com.apple.security.virtualization"]
        case .vmnet:
            ["com.apple.developer.networking.vmnet"]
        case .accessoryAccess:
            ["com.apple.developer.accessory-access.usb"]
        }
    }

    func grantedEntitlementKey(
        lookup: (String) -> Bool = VMHostCapability.entitlementValue
    ) -> String? {
        entitlementKeys.first(where: lookup)
    }

    var isGranted: Bool {
        grantedEntitlementKey() != nil
    }

    private static func entitlementValue(for key: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? Bool == true
    }
}

struct VMUSBDeviceDescriptorSummary: Equatable, Identifiable {
    let registryID: UInt64
    let vendorID: UInt16
    let productID: UInt16

    var id: UInt64 { registryID }

    var title: String {
        String(format: "USB %04X:%04X", vendorID, productID)
    }

    static func parse(registryID: UInt64, descriptor: Data) -> VMUSBDeviceDescriptorSummary? {
        guard descriptor.count >= 12, descriptor[0] >= 12, descriptor[1] == 1 else { return nil }
        let vendorID = UInt16(descriptor[8]) | (UInt16(descriptor[9]) << 8)
        let productID = UInt16(descriptor[10]) | (UInt16(descriptor[11]) << 8)
        return VMUSBDeviceDescriptorSummary(
            registryID: registryID,
            vendorID: vendorID,
            productID: productID
        )
    }
}

enum VMUSBDeviceOperation: Equatable {
    case attaching
    case detaching
}

enum VMUSBPassthroughNotice: Equatable {
    case unexpectedDisconnect(deviceTitle: String)
    case attachFailed(deviceTitle: String, detail: String)
    case detachFailed(deviceTitle: String, detail: String)

    var message: String {
        switch self {
        case .unexpectedDisconnect(let deviceTitle):
            "\(deviceTitle) was disconnected from the virtual machine."
        case .attachFailed(let deviceTitle, let detail):
            "Could not connect \(deviceTitle). Make sure it is approved, connected, and not in use by another app. \(detail)"
        case .detachFailed(let deviceTitle, let detail):
            "Could not disconnect \(deviceTitle). It may still be attached; disconnect it before saving machine state. \(detail)"
        }
    }
}

struct VMUSBPassthroughSnapshot: Equatable {
    var devices: [VMUSBDeviceDescriptorSummary]
    var attachedRegistryIDs: Set<UInt64>
    var operations: [UInt64: VMUSBDeviceOperation] = [:]
    var notice: VMUSBPassthroughNotice?

    var hasAttachedDevices: Bool { !attachedRegistryIDs.isEmpty }
}

enum VMUSBControllerSupport {
    static func canSaveMachineState(
        backendSupportsSaveRestore: Bool,
        attachedAccessoryCount: Int
    ) -> Bool {
        backendSupportsSaveRestore && attachedAccessoryCount == 0
    }

    static func addEmptyXHCIController(to configuration: VZVirtualMachineConfiguration) {
        guard configuration.usbControllers.isEmpty else { return }
        configuration.usbControllers = [VZXHCIControllerConfiguration()]
    }

    static func registryID<Device: AnyObject>(
        forDisconnected device: Device,
        in attachedDevices: [UInt64: Device]
    ) -> UInt64? {
        attachedDevices.first(where: { $0.value === device })?.key
    }
}

enum VMConfigurationIdentity {
    static let maximumLabelLength = 64

    static func label(for machineName: String) -> String? {
        let trimmed = machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumLabelLength))
    }

    static func apply(machineName: String, to configuration: VZVirtualMachineConfiguration) {
        configuration.label = label(for: machineName)
    }
}

/// Tracks whether a VM bundle belongs to the current creation attempt so a
/// failed install can remove its partial files without ever deleting a folder
/// that existed before the user clicked Create.
struct VMCreationDirectoryTransaction {
    let rootURL: URL
    let existedBeforeCreation: Bool

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        existedBeforeCreation = fileManager.fileExists(atPath: rootURL.path)
    }

    func rollback(fileManager: FileManager = .default) throws {
        guard !existedBeforeCreation, fileManager.fileExists(atPath: rootURL.path) else { return }
        try fileManager.removeItem(at: rootURL)
    }
}

final class VMOperationCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}


#if arch(arm64)
enum VMPreinstalledSparseStreamDecoder {
    static func decode(
        from input: FileHandle,
        to outputURL: URL,
        expectedSize: UInt64,
        shouldCancel: () -> Bool = { Task.isCancelled }
    ) throws {
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        guard try readLine(input) == "EZVM-SPARSE-1",
              let sizeLine = try readLine(input), let logicalSize = UInt64(sizeLine),
              logicalSize == expectedSize else {
            throw DecodeError.invalidHeader
        }
        try output.truncate(atOffset: logicalSize)
        while let line = try readLine(input) {
            if shouldCancel() { throw CancellationError() }
            if line == "END" { return }
            let values = line.split(separator: " ")
            guard values.count == 2,
                  let offset = UInt64(values[0]), let length = UInt64(values[1]),
                  offset <= logicalSize, length <= logicalSize - offset else {
                throw DecodeError.invalidExtent
            }
            try output.seek(toOffset: offset)
            var remaining = length
            while remaining > 0 {
                if shouldCancel() { throw CancellationError() }
                let count = Int(min(remaining, 4 * 1024 * 1024))
                let data = try readExactly(input, count: count)
                try output.write(contentsOf: data)
                remaining -= UInt64(data.count)
            }
            guard try input.read(upToCount: 1) == Data([0x0a]) else { throw DecodeError.invalidExtent }
        }
        throw DecodeError.truncated
    }

    private static func readLine(_ handle: FileHandle) throws -> String? {
        var data = Data()
        while data.count <= 128 {
            guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
                return data.isEmpty ? nil : String(data: data, encoding: .utf8)
            }
            if byte[0] == 0x0a { return String(data: data, encoding: .utf8) }
            data.append(byte)
        }
        throw DecodeError.invalidHeader
    }

    private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
                throw DecodeError.truncated
            }
            result.append(chunk)
        }
        return result
    }

    enum DecodeError: LocalizedError, Equatable {
        case invalidHeader, invalidExtent, truncated
        var errorDescription: String? {
            switch self {
            case .invalidHeader: "The sparse image header is invalid."
            case .invalidExtent: "The sparse image contains an invalid extent."
            case .truncated: "The sparse image stream ended unexpectedly."
            }
        }
    }
}

enum VMCPUResourceRecommendation {
    static func recommended(
        hostCPUCount: Int,
        minimumCPUCount: Int,
        maximumCPUCount: Int
    ) -> Int {
        // Interactive guests rarely benefit from consuming nearly every host
        // core. Keep two logical processors for macOS and cap the initial
        // allocation at six; users can still raise it in Hardware settings.
        let hostAwareCount = max(hostCPUCount - 2, minimumCPUCount)
        return min(max(hostAwareCount, minimumCPUCount), min(6, maximumCPUCount))
    }
}

struct VMPreinstalledImageResourceRecommendation: Equatable {
    static let gibibyte: UInt64 = 1024 * 1024 * 1024

    let cpuCount: Int
    let memorySize: UInt64

    static func recommended(
        hostCPUCount: Int = ProcessInfo.processInfo.processorCount,
        hostMemorySize: UInt64 = ProcessInfo.processInfo.physicalMemory,
        minimumCPUCount: Int = VZVirtualMachineConfiguration.minimumAllowedCPUCount,
        maximumCPUCount: Int = VZVirtualMachineConfiguration.maximumAllowedCPUCount,
        minimumMemorySize: UInt64 = VZVirtualMachineConfiguration.minimumAllowedMemorySize,
        maximumMemorySize: UInt64 = VZVirtualMachineConfiguration.maximumAllowedMemorySize
    ) -> Self {
        let cpuCount = VMCPUResourceRecommendation.recommended(
            hostCPUCount: hostCPUCount,
            minimumCPUCount: minimumCPUCount,
            maximumCPUCount: maximumCPUCount
        )

        // Omarchy's full desktop is memory-sensitive. Prefer 8 GiB, but scale
        // down on common 8/16 GiB Macs so the host is not pushed into swap.
        let preferredMemorySize: UInt64
        switch hostMemorySize {
        case ..<(16 * gibibyte):
            preferredMemorySize = 4 * gibibyte
        case ..<(24 * gibibyte):
            preferredMemorySize = 6 * gibibyte
        default:
            preferredMemorySize = 8 * gibibyte
        }
        let memorySize = min(max(preferredMemorySize, minimumMemorySize), maximumMemorySize)

        return Self(cpuCount: cpuCount, memorySize: memorySize)
    }
}

struct VMReleaseSmokeTestConfiguration: Equatable {
    let vmRootPath: URL
    let resultPath: URL
    let processIDPath: URL?
    let requireGuestAgent: Bool
    let requireGuestInput: Bool
    let injectVisibleGuestInput: Bool
    let requireAbsoluteGuestPointer: Bool
    let requireKVM: Bool
    let requireVirGL: Bool
    let requireMemoryBalloon: Bool
    let requireEntropy: Bool
    let requireVirtioSocket: Bool
    let guestAgentEnrollmentURL: URL?
}

enum VMReleaseSmokeTest {
    static let vmPathEnvironmentKey = "EZVM_RELEASE_SMOKE_VM"
    static let resultPathEnvironmentKey = "EZVM_RELEASE_SMOKE_RESULT"
    static let processIDPathEnvironmentKey = "EZVM_RELEASE_SMOKE_PID"
    static let requireGuestAgentEnvironmentKey = "EZVM_RELEASE_REQUIRE_GUEST_AGENT"
    static let requireGuestInputEnvironmentKey = "EZVM_RELEASE_REQUIRE_GUEST_INPUT"
    static let injectVisibleGuestInputEnvironmentKey = "EZVM_RELEASE_INJECT_VISIBLE_INPUT"
    static let requireAbsoluteGuestPointerEnvironmentKey = "EZVM_RELEASE_REQUIRE_ABSOLUTE_POINTER"
    static let requireKVMEnvironmentKey = "EZVM_RELEASE_REQUIRE_KVM"
    static let requireVirGLEnvironmentKey = "EZVM_RELEASE_REQUIRE_VIRGL"
    static let requireMemoryBalloonEnvironmentKey = "EZVM_RELEASE_REQUIRE_MEMORY_BALLOON"
    static let requireEntropyEnvironmentKey = "EZVM_RELEASE_REQUIRE_ENTROPY"
    static let requireVirtioSocketEnvironmentKey = "EZVM_RELEASE_REQUIRE_VIRTIO_SOCKET"
    static let guestAgentEnrollmentEnvironmentKey = "EZVM_RELEASE_AGENT_ENROLLMENT_FILE"

    static func configuration(environment: [String: String] = ProcessInfo.processInfo.environment) -> VMReleaseSmokeTestConfiguration? {
        guard let vmPath = environment[vmPathEnvironmentKey], !vmPath.isEmpty,
              let resultPath = environment[resultPathEnvironmentKey], !resultPath.isEmpty else {
            return nil
        }
        return VMReleaseSmokeTestConfiguration(
            vmRootPath: URL(filePath: vmPath).standardizedFileURL,
            resultPath: URL(filePath: resultPath).standardizedFileURL,
            processIDPath: environment[processIDPathEnvironmentKey].flatMap {
                $0.isEmpty ? nil : URL(filePath: $0).standardizedFileURL
            },
            requireGuestAgent: environment[requireGuestAgentEnvironmentKey] == "1",
            requireGuestInput: environment[requireGuestInputEnvironmentKey] == "1",
            injectVisibleGuestInput: environment[injectVisibleGuestInputEnvironmentKey] == "1",
            requireAbsoluteGuestPointer: environment[requireAbsoluteGuestPointerEnvironmentKey] == "1",
            requireKVM: environment[requireKVMEnvironmentKey] == "1",
            requireVirGL: environment[requireVirGLEnvironmentKey] == "1",
            requireMemoryBalloon: environment[requireMemoryBalloonEnvironmentKey] == "1",
            requireEntropy: environment[requireEntropyEnvironmentKey] == "1",
            requireVirtioSocket: environment[requireVirtioSocketEnvironmentKey] == "1",
            guestAgentEnrollmentURL: environment[guestAgentEnrollmentEnvironmentKey].flatMap {
                $0.isEmpty ? nil : URL(filePath: $0).standardizedFileURL
            }
        )
    }

    static func configuration(for rootPath: URL) -> VMReleaseSmokeTestConfiguration? {
        guard let configuration = configuration(),
              configuration.vmRootPath == rootPath.standardizedFileURL else {
            return nil
        }
        return configuration
    }

    static func report(_ result: String, configuration: VMReleaseSmokeTestConfiguration) {
        do {
            try (result + "\n").write(to: configuration.resultPath, atomically: true, encoding: .utf8)
        } catch {
            let message = "Could not write release smoke result: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    static func reportProcessID(configuration: VMReleaseSmokeTestConfiguration) {
        guard let path = configuration.processIDPath else { return }
        do {
            try "\(getpid())\n".write(to: path, atomically: true, encoding: .utf8)
        } catch {
            report("failed: could not write release smoke process ID: \(error.localizedDescription)", configuration: configuration)
        }
    }
}

enum VirtualizationCapability: String, CaseIterable, Identifiable {
    case savedState, automaticDisplayResize, asifStorage
    case guestProvisioning, diskImageKitSnapshots, customVirtio, efiSecureBoot
    case macOSGuestICloud, macOSGuestMetal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .savedState: "Saved machine state"
        case .automaticDisplayResize: "Automatic display resizing"
        case .asifStorage: "ASIF storage"
        case .guestProvisioning: "macOS guest provisioning"
        case .diskImageKitSnapshots: "DiskImageKit snapshots"
        case .customVirtio: "Custom Virtio devices"
        case .efiSecureBoot: "EFI Secure Boot management"
        case .macOSGuestICloud: "macOS guest iCloud identity"
        case .macOSGuestMetal: "macOS guest Metal improvements"
        }
    }

    var minimumMajorVersion: Int {
        switch self {
        case .savedState, .automaticDisplayResize: 14
        case .asifStorage: 26
        case .macOSGuestICloud: 15
        case .guestProvisioning, .diskImageKitSnapshots, .customVirtio, .efiSecureBoot: 27
        case .macOSGuestMetal: 27
        }
    }

    var isAvailable: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: minimumMajorVersion, minorVersion: 0, patchVersion: 0)
        )
    }
}

enum EZVMExperimentalFeatures {
    static let customVirGLGraphicsKey = "experimental.customVirGLGraphics"

    static func customVirGLGraphicsEnabled(
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.object(forKey: customVirGLGraphicsKey) != nil else {
            return true
        }
        return defaults.bool(forKey: customVirGLGraphicsKey)
    }
}

enum VMGraphicsBackendKind: String, Codable, Equatable {
    case appleVirtio
    case customVirGL
}

struct VMGraphicsBackendSelection: Equatable {
    let requested: VMGraphicsBackendKind
    let active: VMGraphicsBackendKind
    let fallbackReason: String?

    static func resolve(
        isLinux: Bool,
        hostSupportsCustomVirtio: Bool,
        experimentalEnabled: Bool,
        customBackendImplemented: Bool,
        hasInstallationMedia: Bool = false,
        guestInputReady: Bool = true
    ) -> VMGraphicsBackendSelection {
        guard isLinux, experimentalEnabled else {
            return VMGraphicsBackendSelection(
                requested: .appleVirtio, active: .appleVirtio, fallbackReason: nil
            )
        }
        guard hostSupportsCustomVirtio else {
            return VMGraphicsBackendSelection(
                requested: .customVirGL,
                active: .appleVirtio,
                fallbackReason: "The Custom VirGL backend requires macOS 27 or later."
            )
        }
        guard customBackendImplemented else {
            return VMGraphicsBackendSelection(
                requested: .customVirGL,
                active: .appleVirtio,
                fallbackReason: "The Custom VirGL backend is enabled but has not been linked into this build."
            )
        }
        guard !hasInstallationMedia else {
            return VMGraphicsBackendSelection(
                requested: .customVirGL,
                active: .appleVirtio,
                fallbackReason: "Apple Virtio is used while installation media is attached so the installer has reliable keyboard and pointer input."
            )
        }
        guard guestInputReady else {
            return VMGraphicsBackendSelection(
                requested: .customVirGL,
                active: .appleVirtio,
                fallbackReason: "Apple Virtio is used until the EZVM Guest Agent confirms reliable keyboard and pointer input."
            )
        }
        return VMGraphicsBackendSelection(
            requested: .customVirGL, active: .customVirGL, fallbackReason: nil
        )
    }
}

struct VMLinuxFeatureConfiguration: Codable, Equatable {
    var rosettaEnabled: Bool
    var rosettaCachingEnabled: Bool
    var memoryBalloonEnabled: Bool
    var entropyEnabled: Bool
    var virtioSocketEnabled: Bool
    var secureBootEnabled: Bool
    var nestedVirtualizationEnabled: Bool

    static let legacy = VMLinuxFeatureConfiguration(
        rosettaEnabled: false,
        rosettaCachingEnabled: false,
        memoryBalloonEnabled: false,
        entropyEnabled: false,
        virtioSocketEnabled: false,
        secureBootEnabled: false,
        nestedVirtualizationEnabled: false
    )

    static let recommended = VMLinuxFeatureConfiguration(
        rosettaEnabled: false,
        rosettaCachingEnabled: true,
        memoryBalloonEnabled: true,
        entropyEnabled: true,
        virtioSocketEnabled: true,
        secureBootEnabled: false,
        nestedVirtualizationEnabled: false
    )

    private enum CodingKeys: String, CodingKey {
        case rosettaEnabled, rosettaCachingEnabled, memoryBalloonEnabled, entropyEnabled
        case virtioSocketEnabled, secureBootEnabled, nestedVirtualizationEnabled
    }

    init(rosettaEnabled: Bool, rosettaCachingEnabled: Bool, memoryBalloonEnabled: Bool,
         entropyEnabled: Bool, virtioSocketEnabled: Bool, secureBootEnabled: Bool,
         nestedVirtualizationEnabled: Bool) {
        self.rosettaEnabled = rosettaEnabled
        self.rosettaCachingEnabled = rosettaCachingEnabled
        self.memoryBalloonEnabled = memoryBalloonEnabled
        self.entropyEnabled = entropyEnabled
        self.virtioSocketEnabled = virtioSocketEnabled
        self.secureBootEnabled = secureBootEnabled
        self.nestedVirtualizationEnabled = nestedVirtualizationEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rosettaEnabled = try values.decodeIfPresent(Bool.self, forKey: .rosettaEnabled) ?? false
        rosettaCachingEnabled = try values.decodeIfPresent(Bool.self, forKey: .rosettaCachingEnabled) ?? false
        memoryBalloonEnabled = try values.decodeIfPresent(Bool.self, forKey: .memoryBalloonEnabled) ?? false
        entropyEnabled = try values.decodeIfPresent(Bool.self, forKey: .entropyEnabled) ?? false
        virtioSocketEnabled = try values.decodeIfPresent(Bool.self, forKey: .virtioSocketEnabled) ?? false
        secureBootEnabled = try values.decodeIfPresent(Bool.self, forKey: .secureBootEnabled) ?? false
        nestedVirtualizationEnabled = try values.decodeIfPresent(Bool.self, forKey: .nestedVirtualizationEnabled) ?? false
    }
}

extension VMLinuxFeatureConfiguration {
    func applyPlatform(to platform: VZGenericPlatformConfiguration,
                       isSupported: Bool = VZGenericPlatformConfiguration.isNestedVirtualizationSupported) -> VMOSResultVoid {
        guard !nestedVirtualizationEnabled || isSupported else {
            return .failure("Nested virtualization requires an M3 or newer Mac. Disable it in the VM configuration to run this VM on the current host.")
        }
        platform.isNestedVirtualizationEnabled = nestedVirtualizationEnabled
        return .success
    }

    func applyDevices(to configuration: VZVirtualMachineConfiguration, existingDirectoryTags: Set<String>) -> VMOSResultVoid {
        if memoryBalloonEnabled {
            configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        }
        if entropyEnabled {
            configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        }
        if virtioSocketEnabled {
            configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        }

        if rosettaEnabled {
            guard !existingDirectoryTags.contains("rosetta") else {
                return .failure("The directory-sharing tag ‘rosetta’ is reserved when Linux Rosetta is enabled.")
            }
            guard VZLinuxRosettaDirectoryShare.availability == .installed else {
                return .failure("Rosetta for Linux is not installed on this Mac. Disable Rosetta or create the VM again to install it.")
            }
            do {
                let share = try VZLinuxRosettaDirectoryShare()
                if rosettaCachingEnabled {
                    try share.setCachingOptions(.defaultUnixSocket)
                }
                let device = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                device.share = share
                configuration.directorySharingDevices.append(device)
            } catch {
                return .failure("Could not configure Rosetta for Linux: \(error.localizedDescription)")
            }
        }
        return .success
    }
}

@available(macOS 27.0, *)
enum VMEFISecureBootManager {
    static func apply(enabled: Bool, variableStore: VZEFIVariableStore) -> VMOSResultVoid {
        do {
            let isEnabled = try variableStore.isSecureBootEnabled
            if enabled, !isEnabled {
                try variableStore.enrollDefaultSecureBootSignatures()
                try variableStore.enableSecureBootUsingDefaultPlatformKey()
            } else if !enabled, isEnabled {
                try variableStore.disableSecureBoot()
            }
            return .success
        } catch {
            return .failure("Could not update UEFI Secure Boot: \(error.localizedDescription)")
        }
    }

    /// Applies the requested state before a boot. A damaged store must still
    /// reach Virtualization.framework when Secure Boot is off so the existing
    /// one-shot EFI recovery path can replace it and retain the rejected bytes.
    /// Secure Boot opt-in remains strict because silently booting without the
    /// requested trust policy would violate the per-VM configuration.
    static func prepareForBoot(enabled: Bool, variableStore: VZEFIVariableStore) -> VMOSResultVoid {
        let result = apply(enabled: enabled, variableStore: variableStore)
        if !enabled, case .failure = result {
            return .success
        }
        return result
    }
}

struct VMGuestProvisioningCredential: Codable, Equatable {
    let fullName: String
    let username: String
    let password: String
    let logsInAutomatically: Bool
    let enablesRemoteLogin: Bool
}

enum VMGuestProvisioningCredentialPolicy {
    enum Event {
        case virtualMachineStarted
        case userConfirmedSetupCompleted
    }

    static func shouldDeleteCredential(after event: Event) -> Bool {
        switch event {
        case .virtualMachineStarted:
            false
        case .userConfirmedSetupCompleted:
            true
        }
    }
}

enum VMGuestProvisioningCredentialStore {
    private static let service = "com.everettjf.ezvm.guest-provisioning"

    static func save(_ credential: VMGuestProvisioningCredential, vmRootPath: URL) -> VMOSResultVoid {
        do {
            let data = try JSONEncoder().encode(credential)
            let query = baseQuery(vmRootPath: vmRootPath)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
            if status == errSecSuccess { return .success }
            guard status == errSecItemNotFound else { return .failure(message(for: status)) }

            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess ? .success : .failure(message(for: addStatus))
        } catch {
            return .failure("Could not encode guest provisioning credentials: \(error.localizedDescription)")
        }
    }

    static func load(vmRootPath: URL) -> VMOSResult<VMGuestProvisioningCredential?, String> {
        var query = baseQuery(vmRootPath: vmRootPath)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess, let data = result as? Data else {
            return .failure(message(for: status))
        }
        do {
            return .success(try JSONDecoder().decode(VMGuestProvisioningCredential.self, from: data))
        } catch {
            return .failure("The guest provisioning credential in Keychain is invalid: \(error.localizedDescription)")
        }
    }

    static func delete(vmRootPath: URL) -> VMOSResultVoid {
        let status = SecItemDelete(baseQuery(vmRootPath: vmRootPath) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
            ? .success
            : .failure(message(for: status))
    }

    private static func baseQuery(vmRootPath: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey(vmRootPath: vmRootPath),
        ]
    }

    static func accountKey(vmRootPath: URL) -> String {
        var path = vmRootPath.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func message(for status: OSStatus) -> String {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Could not access guest provisioning credentials in Keychain: \(detail)"
    }
}

enum VMDiskImageFormat: String, Codable, CaseIterable, Identifiable {
    case raw
    case asif

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .raw: "img"
        case .asif: "asif"
        }
    }
}

struct VMDiskImageManager {
    struct Command: Equatable {
        let executable: String
        let arguments: [String]
    }

    static func creationCommand(format: VMDiskImageFormat, url: URL, size: UInt64) -> Command? {
        guard format == .asif else { return nil }
        return Command(
            executable: "/usr/sbin/diskutil",
            arguments: [
                "image", "create", "blank",
                "--format", "ASIF",
                "--size", String(size),
                "--fs", "None",
                url.path(percentEncoded: false),
            ]
        )
    }

    static func conversionCommand(sourceURL: URL, destinationURL: URL) -> Command {
        Command(
            executable: "/usr/sbin/diskutil",
            arguments: [
                "image", "create", "from",
                "--format", "ASIF",
                sourceURL.path(percentEncoded: false),
                destinationURL.path(percentEncoded: false),
            ]
        )
    }

    static func create(format: VMDiskImageFormat, at url: URL, size: UInt64) -> VMOSResultVoid {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            let matches: Bool
            switch format {
            case .raw:
                matches = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    .map { UInt64($0) == size } ?? false
            case .asif:
                // ASIF is sparse, so its physical file size is unrelated to
                // its logical capacity. Once created, the image itself is the
                // capacity authority and must never be recreated on startup.
                matches = existingASIFImageHasValidHeader(url: url)
            }
            guard matches else {
                return .failure("A disk image already exists at the destination with a different format or size.")
            }
            return .success
        }

        switch format {
        case .raw:
            return createRaw(at: url, size: size)
        case .asif:
            guard let command = creationCommand(format: format, url: url, size: size) else {
                return .failure("Could not prepare the ASIF creation command.")
            }
            let result = run(command)
            if case .failure = result { try? FileManager.default.removeItem(at: url) }
            return result
        }
    }

    static func convertRawToASIF(sourceURL: URL, destinationURL: URL) -> VMOSResultVoid {
        guard FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
            return .failure("The source disk image does not exist.")
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) else {
            return .failure("The destination disk image already exists.")
        }
        return convertRawToASIF(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            executor: run
        )
    }

    static func convertRawToASIF(
        sourceURL: URL,
        destinationURL: URL,
        availableCapacityBytes: Int64? = nil,
        executor: (Command) -> VMOSResultVoid
    ) -> VMOSResultVoid {
        guard FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
            return .failure("The source disk image does not exist.")
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) else {
            return .failure("The destination disk image already exists.")
        }
        do {
            let values = try sourceURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            let requiredBytes = Int64(max(0, values.totalFileAllocatedSize ?? values.fileSize ?? 0))
            try VMStorageCapacity.validate(
                requiredBytes: requiredBytes,
                at: destinationURL,
                availableBytesOverride: availableCapacityBytes
            )
        } catch {
            return .failure("Cannot convert the disk to ASIF: \(error.localizedDescription)")
        }
        let result = executor(conversionCommand(sourceURL: sourceURL, destinationURL: destinationURL))
        if case .failure = result {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        return result
    }

    private static func createRaw(at url: URL, size: UInt64) -> VMOSResultVoid {
        let descriptor = open(url.path(percentEncoded: false), O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor != -1 else {
            return .failure("Cannot create the raw disk image.")
        }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(size)) == 0 else {
            try? FileManager.default.removeItem(at: url)
            return .failure("Could not resize the raw disk image.")
        }
        return .success
    }

    static func existingASIFImageHasValidHeader(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4) else { return false }
        return header == Data([0x73, 0x68, 0x64, 0x77])
    }

    private static func run(_ command: Command) -> VMOSResultVoid {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(message?.isEmpty == false ? message! : "diskutil failed with status \(process.terminationStatus).")
            }
            return .success
        } catch {
            return .failure("Could not run diskutil: \(error.localizedDescription)")
        }
    }
}

enum VMSavedStateStore {
    static func pendingURL(for stateURL: URL) -> URL {
        stateURL.appendingPathExtension("pending")
    }

    static func prepare(stateURL: URL) throws -> URL {
        let pending = pendingURL(for: stateURL)
        try? FileManager.default.removeItem(at: pending)
        return pending
    }

    static func commit(pendingURL: URL, stateURL: URL) throws {
        guard FileManager.default.fileExists(atPath: pendingURL.path(percentEncoded: false)) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if FileManager.default.fileExists(atPath: stateURL.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(stateURL, withItemAt: pendingURL)
        } else {
            try FileManager.default.moveItem(at: pendingURL, to: stateURL)
        }
    }

    static func discardPending(stateURL: URL) {
        try? FileManager.default.removeItem(at: pendingURL(for: stateURL))
    }

    static func recoverInterruptedTransaction(stateURL: URL) {
        discardPending(stateURL: stateURL)
    }
}

enum VMEFIVariableStoreRecovery {
    static func isInvalidBootLoaderError(_ message: String) -> Bool {
        let value = message.lowercased()
        return value.contains("boot loader") && value.contains("invalid")
    }

    /// Replaces a store only after Virtualization.framework explicitly rejects
    /// its boot loader. The rejected bytes are retained for diagnostics.
    static func replaceRejectedStore(at storeURL: URL) throws -> URL? {
        let fileManager = FileManager.default
        let replacementURL = storeURL.appendingPathExtension("replacement")
        let backupURL = storeURL.appendingPathExtension("invalid-backup")
        try? fileManager.removeItem(at: replacementURL)
        try? fileManager.removeItem(at: backupURL)
        _ = try VZEFIVariableStore(creatingVariableStoreAt: replacementURL)

        let hadOriginal = fileManager.fileExists(atPath: storeURL.path)
        if hadOriginal {
            try fileManager.moveItem(at: storeURL, to: backupURL)
        }
        do {
            try fileManager.moveItem(at: replacementURL, to: storeURL)
            return hadOriginal ? backupURL : nil
        } catch {
            try? fileManager.removeItem(at: replacementURL)
            if hadOriginal, !fileManager.fileExists(atPath: storeURL.path) {
                try? fileManager.moveItem(at: backupURL, to: storeURL)
            }
            throw error
        }
    }
}

class VMOSHelper {

    // Create an empty disk image for the Virtual Machine.
    static func createEmptyDiskImage(filePath: URL, size: UInt64) -> VMOSResultVoid {
        VMDiskImageManager.create(format: .raw, at: filePath, size: size)
    }
    
    // Create an empty disk image for the Virtual Machine.
    static func createEmptyDiskImage(filePath: URL, size: UInt64) async throws {
        return try await withCheckedThrowingContinuation({ continuation in
            let result = createEmptyDiskImage(filePath: filePath, size: size)
            if case let .failure(error) = result {
                continuation.resume(throwing: VMOSError.regularFailure(error))
                return
            }
            continuation.resume(returning: ())
        })
    }
}

struct VMMacOSCatalogPayload: Codable, Equatable {
    let firmwares: [Firmware]

    struct Firmware: Codable, Equatable {
        let version: String
        let buildid: String
        let filesize: Int64
        let url: URL
        let signed: Bool
    }

    var availableFirmwares: [Firmware] {
        var seen = Set<String>()
        return firmwares
            .filter { firmware in
                guard firmware.signed,
                      firmware.filesize > 0,
                      firmware.url.scheme?.lowercased() == "https",
                      let host = firmware.url.host?.lowercased(),
                      host == "apple.com" || host.hasSuffix(".apple.com") || host == "updates.cdn-apple.com",
                      !firmware.version.isEmpty,
                      !firmware.buildid.isEmpty else { return false }
                return seen.insert("\(firmware.version)-\(firmware.buildid)").inserted
            }
            .sorted {
                let versionOrder = $0.version.compare($1.version, options: .numeric)
                return versionOrder == .orderedSame ? $0.buildid > $1.buildid : versionOrder == .orderedDescending
            }
    }
}

struct VMMacOSCatalogCache: Codable, Equatable {
    let fetchedAt: Date
    let payload: VMMacOSCatalogPayload
}

enum VMRuntimePhase: Equatable {
    case preparing
    case starting
    case restoring
    case running
    case pausing
    case paused
    case saving
    case stopping
    case stopped
    case failed(String)

    var title: String {
        switch self {
        case .preparing: "Preparing"
        case .starting: "Starting"
        case .restoring: "Restoring"
        case .running: "Running"
        case .pausing: "Pausing"
        case .paused: "Paused"
        case .saving: "Saving"
        case .stopping: "Stopping"
        case .stopped: "Stopped"
        case .failed: "Error"
        }
    }

    // A VZVirtualMachine cannot be started again after it reaches the stopped
    // state. Dismantling its scene makes the next Run action create a fresh
    // controller and VZVirtualMachine instance.
    var shouldDismissMachineWindow: Bool {
        self == .stopped
    }

    func canSaveMachineState(backendSupportsSaveRestore: Bool) -> Bool {
        backendSupportsSaveRestore && (self == .running || self == .paused)
    }
}

enum VMDownloadValidationError: LocalizedError, Equatable {
    case emptyFile
    case sizeMismatch(expected: Int64, actual: Int64)
    case insufficientDiskSpace(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .emptyFile: "The server returned an empty file."
        case let .sizeMismatch(expected, actual): "Expected \(expected) bytes but downloaded \(actual) bytes."
        case let .insufficientDiskSpace(required, available):
            "The operation needs \(required) bytes, but only \(available) bytes are available."
        }
    }
}

enum VMStorageCapacity {
    static func availableBytes(at url: URL) -> Int64? {
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        return (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    static func validate(
        requiredBytes: Int64?,
        at url: URL,
        reserveBytes: Int64 = 1_073_741_824,
        availableBytesOverride: Int64? = nil
    ) throws {
        guard let requiredBytes, requiredBytes > 0,
              let available = availableBytesOverride ?? availableBytes(at: url) else { return }
        let (sum, overflow) = requiredBytes.addingReportingOverflow(max(0, reserveBytes))
        let requiredWithReserve = overflow ? Int64.max : sum
        guard available < requiredWithReserve else { return }
        throw VMDownloadValidationError.insufficientDiskSpace(required: requiredWithReserve, available: available)
    }
}

enum VMThumbnailValidator {
    static func isMeaningfulRGBA(
        _ pixels: [UInt8],
        brightnessThreshold: UInt8 = 18,
        minimumBrightFraction: Double = 0.01
    ) -> Bool {
        guard pixels.count >= 4, pixels.count.isMultiple(of: 4) else { return false }
        var brightPixels = 0
        let pixelCount = pixels.count / 4
        let requiredBrightPixels = max(1, Int(ceil(Double(pixelCount) * minimumBrightFraction)))
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            if max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) > brightnessThreshold {
                brightPixels += 1
                if brightPixels >= requiredBrightPixels { return true }
            }
        }
        return false
    }
}

enum VMThumbnailPreferences {
    static let screenCaptureEnabledKey = "thumbnail.screen-capture-enabled"
    static let generatedStyleKey = "thumbnail.generated-style"

    static func generatedStyleKey(for rootPath: URL) -> String {
        "\(generatedStyleKey).vm.\(rootPath.standardizedFileURL.path(percentEncoded: true))"
    }
}

enum VMSharedFolderPathStatus: Equatable {
    case available
    case missing
    case notDirectory
    case unreadable

    var message: String? {
        switch self {
        case .available: nil
        case .missing: "Folder not found"
        case .notDirectory: "This item is not a folder"
        case .unreadable: "Folder is not readable"
        }
    }
}

enum VMSharedFolderPathValidator {
    static func status(for url: URL, fileManager: FileManager = .default) -> VMSharedFolderPathStatus {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue else { return .notDirectory }
        guard fileManager.isReadableFile(atPath: path) else { return .unreadable }
        return .available
    }
}

enum VMSystemImageFileValidator {
    static func validate(
        _ url: URL,
        expectedExtension: String,
        expectedSize: Int64? = nil
    ) -> String? {
        let normalizedExtension = expectedExtension.lowercased()
        guard url.pathExtension.lowercased() == normalizedExtension else {
            return "Expected a .\(normalizedExtension) system image."
        }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0 else {
            return "The system image is missing, empty, or not a regular file."
        }
        if let expectedSize, Int64(fileSize) != expectedSize {
            return "The cached system image has the wrong size and must be downloaded again."
        }
        return nil
    }

    static func validateSHA256(_ url: URL, expectedSHA256: String) -> String? {
        guard expectedSHA256.count == 64, expectedSHA256.allSatisfy(\.isHexDigit) else {
            return "The catalog contains an invalid SHA-256 value."
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
                hasher.update(data: data)
            }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expectedSHA256.lowercased() else {
                return "The system image SHA-256 does not match the vendor catalog."
            }
            return nil
        } catch {
            return "The system image could not be hashed: \(error.localizedDescription)"
        }
    }
}

#endif
