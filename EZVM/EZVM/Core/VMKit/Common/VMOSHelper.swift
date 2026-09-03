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

enum VMCreationCancellationKind: Equatable {
    case download
    case installation
}

enum VMCreationCancellationPolicy {
    static func buttonTitle(for kind: VMCreationCancellationKind?) -> String {
        switch kind {
        case .download: "Cancel Download"
        case .installation: "Cancel Installation"
        case nil: "Close"
        }
    }

    static func shouldDismissGuideAfterRequest(
        _ kind: VMCreationCancellationKind?
    ) -> Bool {
        kind != .installation
    }
}

enum VMDiagnosticSanitizer {
    private static let removedKeys: Set<String> = [
        "id", "imagepath", "name", "path", "remark"
    ]
    private static let secretKeyFragments = [
        "credential", "password", "secret", "serial", "token"
    ]

    static func sanitizedConfiguration(data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let output = try? JSONSerialization.data(
                withJSONObject: sanitize(object),
                options: [.prettyPrinted, .sortedKeys]
              ) else { return nil }
        return String(data: output, encoding: .utf8)
    }

    static func sanitizedLogMessage(
        _ message: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        machinePaths: [String]
    ) -> String {
        ([homeDirectory] + machinePaths)
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .reduce(message) { result, path in
                result.replacingOccurrences(
                    of: path,
                    with: path == homeDirectory ? "<home>" : "<vm-bundle>"
                )
            }
    }

    static func errorIdentifier(_ error: Error) -> String {
        let error = error as NSError
        return "domain=\(error.domain) code=\(error.code)"
    }

    private static func sanitize(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                let normalizedKey = entry.key.lowercased()
                if removedKeys.contains(normalizedKey) { return }
                if secretKeyFragments.contains(where: normalizedKey.contains) {
                    result[entry.key] = "<redacted>"
                } else if normalizedKey == "networkidentifier" {
                    result[entry.key] = "<configured>"
                } else {
                    result[entry.key] = sanitize(entry.value)
                }
            }
        }
        if let array = value as? [Any] { return array.map(sanitize) }
        if let string = value as? String,
           string.hasPrefix("/") || string.lowercased().hasPrefix("file:") {
            return "<redacted-path>"
        }
        return value
    }
}

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

    static func diagnosticSummary(
        entitlementLookup: (String) -> Bool,
        diskImageKitIncluded: Bool,
        customVirGLIncluded: Bool
    ) -> [String] {
        var lines = allCases.map { capability in
            let state = capability.grantedEntitlementKey(lookup: entitlementLookup) == nil
                ? "missing entitlement"
                : "entitlement present"
            return "\(capability.title): \(state)"
        }
        lines.append("DiskImageKit / ASIF snapshots: \(diskImageKitIncluded ? "included" : "unavailable in this build")")
        lines.append("Custom Virtio GPU / VirGL: \(customVirGLIncluded ? "included" : "unavailable in this build")")
        return lines
    }
}

struct VMUSBDeviceDescriptorSummary: Equatable, Identifiable {
    let registryID: UInt64
    let vendorID: UInt16
    let productID: UInt16
    let manufacturerName: String?
    let productName: String?

    var id: UInt64 { registryID }

    init(
        registryID: UInt64,
        vendorID: UInt16,
        productID: UInt16,
        manufacturerName: String? = nil,
        productName: String? = nil
    ) {
        self.registryID = registryID
        self.vendorID = vendorID
        self.productID = productID
        self.manufacturerName = Self.sanitizedDisplayName(manufacturerName)
        self.productName = Self.sanitizedDisplayName(productName)
    }

    var title: String {
        if let productName {
            if let manufacturerName,
               !productName.localizedCaseInsensitiveContains(manufacturerName) {
                return "\(manufacturerName) \(productName)"
            }
            return productName
        }
        if let manufacturerName {
            return "\(manufacturerName) USB Device"
        }
        return String(format: "USB %04X:%04X", vendorID, productID)
    }

    var identifier: String {
        String(format: "%04X:%04X", vendorID, productID)
    }

    var menuTitle: String {
        manufacturerName == nil && productName == nil ? title : "\(title) · \(identifier)"
    }

    static func parse(
        registryID: UInt64,
        descriptor: Data,
        manufacturerName: String? = nil,
        productName: String? = nil
    ) -> VMUSBDeviceDescriptorSummary? {
        guard descriptor.count >= 12, descriptor[0] >= 12, descriptor[1] == 1 else { return nil }
        let vendorID = UInt16(descriptor[8]) | (UInt16(descriptor[9]) << 8)
        let productID = UInt16(descriptor[10]) | (UInt16(descriptor[11]) << 8)
        return VMUSBDeviceDescriptorSummary(
            registryID: registryID,
            vendorID: vendorID,
            productID: productID,
            manufacturerName: manufacturerName,
            productName: productName
        )
    }

    private static func sanitizedDisplayName(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalarView = value.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
        let normalized = String(String.UnicodeScalarView(scalarView))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(80))
    }
}

enum VMUSBDeviceOperation: Equatable {
    case attaching
    case detaching
}

struct VMUSBListenerLifecycle {
    private enum State: Equatable {
        case idle
        case registering(UUID)
        case registered
        case stopped
    }

    private var state: State = .idle

    var isRegistering: Bool {
        if case .registering = state { return true }
        return false
    }
    var isRegistered: Bool { state == .registered }
    var acceptsAccessoryCallbacks: Bool { state == .registered }

    mutating func beginRegistration() -> UUID? {
        guard !isRegistering, !isRegistered else { return nil }
        let token = UUID()
        state = .registering(token)
        return token
    }

    mutating func completeRegistration(token: UUID) -> Bool {
        guard state == .registering(token) else { return false }
        state = .registered
        return true
    }

    mutating func failRegistration(token: UUID) -> Bool {
        guard state == .registering(token) else { return false }
        state = .idle
        return true
    }

    mutating func stop() -> Bool {
        let shouldUnregister = state == .registered
        state = .stopped
        return shouldUnregister
    }
}

enum VMUSBFailureKind: Equatable {
    case listenerAlreadyRegistered
    case accessoryNotAccessible
    case invalidAccessoryState
    case controllerNotFound
    case deviceAlreadyAttached
    case deviceInitializationFailure
    case deviceNotFound
    case internalFailure
    case other
}

enum VMUSBFailureFramework {
    case accessoryAccess
    case virtualization
    case other
}

enum VMUSBFailureGuidance {
    static func classify(framework: VMUSBFailureFramework, code: Int) -> VMUSBFailureKind {
        switch (framework, code) {
        case (.accessoryAccess, 1): .internalFailure
        case (.accessoryAccess, 2): .listenerAlreadyRegistered
        case (.accessoryAccess, 3): .accessoryNotAccessible
        case (.accessoryAccess, 4): .invalidAccessoryState
        case (.virtualization, 30001): .controllerNotFound
        case (.virtualization, 30002): .deviceAlreadyAttached
        case (.virtualization, 30003): .deviceInitializationFailure
        case (.virtualization, 30004): .deviceNotFound
        default: .other
        }
    }

    static func message(for kind: VMUSBFailureKind, fallback: String) -> String {
        switch kind {
        case .listenerAlreadyRegistered:
            "Accessory Access is already active in another EZVM virtual machine window. Close that virtual machine or release its USB accessories, then try again."
        case .accessoryNotAccessible:
            "This accessory is being used by macOS or another app. Release it from the accessory menu, then choose it for EZVM again."
        case .invalidAccessoryState:
            "This accessory is no longer in a state that can be attached. Disconnect it from the Mac, reconnect it, and approve it for EZVM again."
        case .controllerNotFound:
            "The running virtual machine no longer has an available USB controller. Restart the virtual machine and try again."
        case .deviceAlreadyAttached:
            "The USB device is already attached. Wait for the device list to refresh before trying another action."
        case .deviceInitializationFailure:
            "The guest could not initialize this USB device. Safely reconnect the device and try again; this device class may not support passthrough."
        case .deviceNotFound:
            "The USB device is no longer connected to this virtual machine. Reconnect it to the Mac and approve it for EZVM again."
        case .internalFailure:
            "Accessory Access could not complete the operation. Try again; if it repeats, restart EZVM and reconnect the accessory."
        case .other:
            fallback
        }
    }

    static func confirmsDeviceIsDisconnected(_ kind: VMUSBFailureKind) -> Bool {
        kind == .deviceNotFound
    }
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
            "Could not connect \(deviceTitle). \(detail)"
        case .detachFailed(let deviceTitle, let detail):
            "Could not disconnect \(deviceTitle). It may still be attached, so machine-state saving remains unavailable. \(detail)"
        }
    }
}

struct VMUSBPassthroughSnapshot: Equatable {
    var devices: [VMUSBDeviceDescriptorSummary]
    var attachedRegistryIDs: Set<UInt64>
    var operations: [UInt64: VMUSBDeviceOperation] = [:]
    var notice: VMUSBPassthroughNotice?

    var hasAttachedDevices: Bool { !attachedRegistryIDs.isEmpty }
    var canChooseMoreAccessories: Bool {
        attachedRegistryIDs.isEmpty && operations.isEmpty
    }
}

enum VMUSBControllerSupport {
    enum DisconnectDisposition: Equatable {
        case ignored
        case attachInterrupted
        case explicitDetach
        case unexpected
    }

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

    /// Invalidating operation tokens is the cancellation boundary available
    /// for asynchronous USB controller operations. A late attach completion
    /// observes the missing token and immediately detaches its device instead
    /// of promoting it into the VM while shutdown is already underway.
    static func fenceOperationsForMachineStop(
        operationTokens: inout [UInt64: UUID]
    ) {
        operationTokens.removeAll()
    }

    static func operationIsCurrent(
        registryID: UInt64,
        token: UUID,
        operationTokens: [UInt64: UUID]
    ) -> Bool {
        operationTokens[registryID] == token
    }

    static func registryID<Device: AnyObject>(
        forDisconnected device: Device,
        in attachedDevices: [UInt64: Device]
    ) -> UInt64? {
        attachedDevices.first(where: { $0.value === device })?.key
    }

    static func registryID<Device: AnyObject>(
        forDisconnected device: Device,
        attachedDevices: [UInt64: Device],
        pendingDevices: [UInt64: Device]
    ) -> UInt64? {
        registryID(forDisconnected: device, in: attachedDevices)
            ?? registryID(forDisconnected: device, in: pendingDevices)
    }

    /// Reconciles the two independent disconnect signals delivered by
    /// Accessory Access and Virtualization. The first signal owns cleanup and
    /// user feedback; a duplicate or late signal is deliberately a no-op.
    static func reconcileDisconnect(
        registryID: UInt64,
        attachedRegistryIDs: inout Set<UInt64>,
        operations: inout [UInt64: VMUSBDeviceOperation],
        operationTokens: inout [UInt64: UUID]
    ) -> DisconnectDisposition {
        guard attachedRegistryIDs.remove(registryID) != nil else {
            let operation = operations.removeValue(forKey: registryID)
            operationTokens.removeValue(forKey: registryID)
            return operation == .attaching ? .attachInterrupted : .ignored
        }
        let disposition: DisconnectDisposition = operations[registryID] == .detaching
            ? .explicitDetach
            : .unexpected
        operations.removeValue(forKey: registryID)
        operationTokens.removeValue(forKey: registryID)
        return disposition
    }
}

enum VMConfigurationIdentity {
    /// `VZVirtualMachineConfiguration.label` is backed by NSString. Keep the
    /// value within the framework's 64-character limit as UTF-16 code units,
    /// while never cutting a Swift grapheme cluster in half.
    static let maximumLabelLength = 64

    static func label(for machineName: String) -> String? {
        let systemServiceSafeName = machineName.unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar) {
                result.append(" ")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        let normalized = systemServiceSafeName
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }

        var label = ""
        var utf16Length = 0
        for character in normalized {
            let characterLength = String(character).utf16.count
            guard utf16Length + characterLength <= maximumLabelLength else { break }
            label.append(character)
            utf16Length += characterLength
        }
        return label.isEmpty ? nil : label
    }

    static func apply(machineName: String, to configuration: VZVirtualMachineConfiguration) {
        configuration.label = label(for: machineName)
    }
}

/// Atomically claims a VM bundle for one creation attempt. Rollback removes
/// only a directory whose successful `mkdir` belongs to this transaction.
final class VMCreationDirectoryTransaction {
    let rootURL: URL
    private(set) var ownsRoot = false

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func createRoot(
        allowedExistingItemNames: Set<String>? = nil,
        fileManager: FileManager = .default
    ) throws {
        guard !ownsRoot else { return }
        var rootPath = rootURL.path(percentEncoded: false)
        while rootPath.count > 1, rootPath.hasSuffix("/") { rootPath.removeLast() }
        do {
            try fileManager.createDirectory(
                at: rootURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw VMOSError.regularFailure(
                "Could not prepare the virtual machine location: \(error.localizedDescription)"
            )
        }
        let status = mkdir(rootPath, S_IRWXU | S_IRWXG | S_IRWXO)
        if status == 0 {
            ownsRoot = true
            return
        }
        guard errno == EEXIST, let allowedExistingItemNames else {
            let detail = errno == EEXIST
                ? "The destination already exists. Choose a new virtual machine location."
                : "Could not create the virtual machine directory: \(String(cString: strerror(errno)))."
            throw VMOSError.regularFailure(detail)
        }
        var metadata = stat()
        guard lstat(rootPath, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            throw VMOSError.regularFailure("The controlled staging path is not a directory.")
        }
        let actualItems = Set(try fileManager.contentsOfDirectory(atPath: rootURL.path))
        guard actualItems == allowedExistingItemNames else {
            throw VMOSError.regularFailure("The controlled staging directory contains unexpected files.")
        }
    }

    func rollback(fileManager: FileManager = .default) throws {
        guard ownsRoot, fileManager.fileExists(atPath: rootURL.path) else { return }
        try fileManager.removeItem(at: rootURL)
        ownsRoot = false
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
    let requireASIFStorage: Bool
    let requireVMNet: Bool
    let requireGuestIPv4: Bool
    let requireMachineStateSupport: Bool
    let saveMachineState: Bool
    let forceAppleGraphics: Bool
    let holdSeconds: Int
    let holdReadyURL: URL?
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
    static let requireASIFStorageEnvironmentKey = "EZVM_RELEASE_REQUIRE_ASIF_STORAGE"
    static let requireVMNetEnvironmentKey = "EZVM_RELEASE_REQUIRE_VMNET"
    static let requireGuestIPv4EnvironmentKey = "EZVM_RELEASE_REQUIRE_GUEST_IPV4"
    static let requireMachineStateSupportEnvironmentKey = "EZVM_RELEASE_REQUIRE_MACHINE_STATE_SUPPORT"
    static let saveMachineStateEnvironmentKey = "EZVM_RELEASE_SAVE_MACHINE_STATE"
    static let forceAppleGraphicsEnvironmentKey = "EZVM_RELEASE_FORCE_APPLE_GRAPHICS"
    static let holdSecondsEnvironmentKey = "EZVM_RELEASE_HOLD_SECONDS"
    static let holdReadyEnvironmentKey = "EZVM_RELEASE_HOLD_READY"
    static let guestAgentEnrollmentEnvironmentKey = "EZVM_RELEASE_AGENT_ENROLLMENT_FILE"

    static func canFinishHold(
        guestStatus: VMGuestAgentStatus?,
        requireGuestIPv4: Bool
    ) -> Bool {
        guard let status = guestStatus else { return false }
        return !requireGuestIPv4 || status.hasIPv4Address
    }

    static func configuration(environment: [String: String] = ProcessInfo.processInfo.environment) -> VMReleaseSmokeTestConfiguration? {
        guard let vmPath = environment[vmPathEnvironmentKey], !vmPath.isEmpty,
              let resultPath = environment[resultPathEnvironmentKey], !resultPath.isEmpty else {
            return nil
        }
        let requestedHold = environment[holdSecondsEnvironmentKey].flatMap(Int.init) ?? 0
        let holdSeconds = (0...600).contains(requestedHold) ? requestedHold : 0
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
            requireASIFStorage: environment[requireASIFStorageEnvironmentKey] == "1",
            requireVMNet: environment[requireVMNetEnvironmentKey] == "1",
            requireGuestIPv4: environment[requireGuestIPv4EnvironmentKey] == "1",
            requireMachineStateSupport: environment[requireMachineStateSupportEnvironmentKey] == "1",
            saveMachineState: environment[saveMachineStateEnvironmentKey] == "1",
            forceAppleGraphics: environment[forceAppleGraphicsEnvironmentKey] == "1",
            holdSeconds: holdSeconds,
            holdReadyURL: environment[holdReadyEnvironmentKey].flatMap {
                $0.isEmpty ? nil : URL(filePath: $0).standardizedFileURL
            },
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

enum VMReleaseSnapshotAction: String, Equatable {
    case create, audit, restore
}

struct VMReleaseSnapshotTestConfiguration: Equatable {
    let action: VMReleaseSnapshotAction
    let vmRootPath: URL
    let resultPath: URL
    let snapshotID: String?

    static let actionEnvironmentKey = "EZVM_RELEASE_SNAPSHOT_ACTION"
    static let vmPathEnvironmentKey = "EZVM_RELEASE_SNAPSHOT_VM"
    static let resultPathEnvironmentKey = "EZVM_RELEASE_SNAPSHOT_RESULT"
    static let snapshotIDEnvironmentKey = "EZVM_RELEASE_SNAPSHOT_ID"

    static func configuration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self? {
        guard let actionValue = environment[actionEnvironmentKey],
              let action = VMReleaseSnapshotAction(rawValue: actionValue),
              let vmPath = environment[vmPathEnvironmentKey], !vmPath.isEmpty,
              let resultPath = environment[resultPathEnvironmentKey], !resultPath.isEmpty else {
            return nil
        }
        let snapshotID = environment[snapshotIDEnvironmentKey].flatMap { value in
            UUID(uuidString: value) == nil ? nil : value
        }
        guard action == .create || snapshotID != nil else { return nil }
        return Self(
            action: action,
            vmRootPath: URL(filePath: vmPath).standardizedFileURL,
            resultPath: URL(filePath: resultPath).standardizedFileURL,
            snapshotID: snapshotID
        )
    }

    func report(_ value: String) {
        do {
            try (value + "\n").write(to: resultPath, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(
                Data("Could not write snapshot release result: \(error.localizedDescription)\n".utf8)
            )
        }
    }
}

enum VMReleasePortabilityAction: String, Equatable {
    case export, validate, `import`

    var successResult: String {
        switch self {
        case .export: "exported"
        case .validate: "validated"
        case .import: "imported"
        }
    }
}

struct VMReleasePortabilityTestConfiguration: Equatable {
    let action: VMReleasePortabilityAction
    let inputURL: URL
    let outputURL: URL?
    let resultURL: URL

    static let actionEnvironmentKey = "EZVM_RELEASE_PORTABILITY_ACTION"
    static let inputEnvironmentKey = "EZVM_RELEASE_PORTABILITY_INPUT"
    static let outputEnvironmentKey = "EZVM_RELEASE_PORTABILITY_OUTPUT"
    static let resultEnvironmentKey = "EZVM_RELEASE_PORTABILITY_RESULT"

    static func configuration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self? {
        guard let actionValue = environment[actionEnvironmentKey],
              let action = VMReleasePortabilityAction(rawValue: actionValue),
              let input = environment[inputEnvironmentKey], !input.isEmpty,
              let result = environment[resultEnvironmentKey], !result.isEmpty else {
            return nil
        }
        let output = environment[outputEnvironmentKey].flatMap { value in
            value.isEmpty ? nil : URL(filePath: value).standardizedFileURL
        }
        guard action == .validate || output != nil else { return nil }
        return Self(
            action: action,
            inputURL: URL(filePath: input).standardizedFileURL,
            outputURL: output,
            resultURL: URL(filePath: result).standardizedFileURL
        )
    }

    func report(_ value: String) {
        do {
            try (value + "\n").write(to: resultURL, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(
                Data("Could not write portability release result: \(error.localizedDescription)\n".utf8)
            )
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

enum VMMachineStateSupport {
    static func unavailabilityReason(
        backendSupportsSaveRestore: Bool,
        configurationValidationFailure: String?,
        attachedAccessoryCount: Int,
        usbOperationInProgress: Bool = false
    ) -> String? {
        if !backendSupportsSaveRestore {
            return "Custom VirGL state cannot be saved."
        }
        if usbOperationInProgress {
            return "Wait for the USB connection or disconnection to finish before saving machine state."
        }
        if attachedAccessoryCount > 0 {
            return "Disconnect USB accessories before saving machine state."
        }
        if let configurationValidationFailure, !configurationValidationFailure.isEmpty {
            return "This virtual machine configuration cannot save state: \(configurationValidationFailure)"
        }
        return nil
    }
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

enum VMGraphicsPresentationHealthTransition: Equatable {
    case none
    case degraded
    case recovered
}

struct VMGraphicsPresentationHealthTracker: Equatable {
    private(set) var consecutiveFailures = 0
    private(set) var isDegraded = false
    let failureThreshold: Int

    init(failureThreshold: Int = 3) {
        self.failureThreshold = max(1, failureThreshold)
    }

    mutating func record(success: Bool) -> VMGraphicsPresentationHealthTransition {
        if success {
            consecutiveFailures = 0
            guard isDegraded else { return .none }
            isDegraded = false
            return .recovered
        }

        consecutiveFailures = min(consecutiveFailures + 1, failureThreshold)
        guard !isDegraded, consecutiveFailures >= failureThreshold else { return .none }
        isDegraded = true
        return .degraded
    }
}

struct VMGraphicsPresentationLifecycle: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var isStopped = false

    func tokenForPresentation() -> UInt64? {
        isStopped ? nil : generation
    }

    func acceptsCompletion(token: UInt64) -> Bool {
        !isStopped && token == generation
    }

    mutating func stop() {
        guard !isStopped else { return }
        isStopped = true
        generation &+= 1
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

enum VMGuestProvisioningAttemptState: String, Codable, Equatable {
    case prepared
    case applying
    case awaitingConfirmation
}

struct VMGuestProvisioningCredential: Codable, Equatable {
    let fullName: String
    let username: String
    let password: String
    let logsInAutomatically: Bool
    let enablesRemoteLogin: Bool
    let attemptID: UUID
    let attemptState: VMGuestProvisioningAttemptState

    init(
        fullName: String,
        username: String,
        password: String,
        logsInAutomatically: Bool,
        enablesRemoteLogin: Bool,
        attemptID: UUID = UUID(),
        attemptState: VMGuestProvisioningAttemptState = .prepared
    ) {
        self.fullName = fullName
        self.username = username
        self.password = password
        self.logsInAutomatically = logsInAutomatically
        self.enablesRemoteLogin = enablesRemoteLogin
        self.attemptID = attemptID
        self.attemptState = attemptState
    }

    private enum CodingKeys: String, CodingKey {
        case fullName, username, password, logsInAutomatically, enablesRemoteLogin
        case attemptID, attemptState
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fullName = try values.decode(String.self, forKey: .fullName)
        username = try values.decode(String.self, forKey: .username)
        password = try values.decode(String.self, forKey: .password)
        logsInAutomatically = try values.decode(Bool.self, forKey: .logsInAutomatically)
        enablesRemoteLogin = try values.decode(Bool.self, forKey: .enablesRemoteLogin)
        attemptID = try values.decodeIfPresent(UUID.self, forKey: .attemptID) ?? UUID()
        attemptState = try values.decodeIfPresent(
            VMGuestProvisioningAttemptState.self,
            forKey: .attemptState
        ) ?? .prepared
    }

    func withAttemptState(_ state: VMGuestProvisioningAttemptState) -> Self {
        Self(
            fullName: fullName,
            username: username,
            password: password,
            logsInAutomatically: logsInAutomatically,
            enablesRemoteLogin: enablesRemoteLogin,
            attemptID: attemptID,
            attemptState: state
        )
    }
}

enum VMGuestProvisioningCredentialPolicy {
    enum Event {
        case virtualMachineStarted
        case userConfirmedSetupCompleted
        case userChoseManualSetup
    }

    static func shouldDeleteCredential(after event: Event) -> Bool {
        switch event {
        case .virtualMachineStarted:
            false
        case .userConfirmedSetupCompleted, .userChoseManualSetup:
            true
        }
    }

    static func shouldSubmitProvisioning(for state: VMGuestProvisioningAttemptState) -> Bool {
        state == .prepared
    }
}

enum VMGuestProvisioningValidationFailure: Equatable {
    case invalidFullName
    case invalidUsername
    case invalidPassword
    case other
}

enum VMGuestProvisioningValidationGuidance {
    static func classify(domain: String, code: Int) -> VMGuestProvisioningValidationFailure {
        guard domain == VZErrorDomain else { return .other }
        switch code {
        case 40001: return .invalidFullName
        case 40002: return .invalidUsername
        case 40003: return .invalidPassword
        default: return .other
        }
    }

    static func message(for error: Error) -> String {
        let error = error as NSError
        switch classify(domain: error.domain, code: error.code) {
        case .invalidFullName:
            return "Enter a different full name for the macOS account. Virtualization.framework rejected this value."
        case .invalidUsername:
            return "Enter a different username for the macOS account. Virtualization.framework rejected this value."
        case .invalidPassword:
            return "Choose a different password for the macOS account. Virtualization.framework rejected this value."
        case .other:
            return "Virtualization.framework rejected the guest provisioning settings. Review the account details and try again."
        }
    }
}

enum VMGuestProvisioningStartFailureGuidance {
    static func message(retryWasPrepared: Bool) -> String {
        if retryWasPrepared {
            return "macOS guest provisioning did not start. The temporary credential was retained and a safe retry is ready for the next VM start."
        }
        return "macOS guest provisioning did not start, and EZVM could not prepare a safe retry. Close this VM window, reopen it, and review the provisioning status before trying again."
    }
}

enum VMGuestProvisioningRetryRecovery {
    static func prepare(
        credential: VMGuestProvisioningCredential,
        vmRootPath: URL,
        save: (VMGuestProvisioningCredential, URL) -> VMOSResultVoid = {
            VMGuestProvisioningCredentialStore.save($0, vmRootPath: $1)
        }
    ) -> VMOSResultVoid {
        save(credential.withAttemptState(.prepared), vmRootPath)
    }
}

enum VMGuestProvisioningCompatibility {
    static let minimumGuestMajorVersion = 27

    static func supportsGuest(version: String) -> Bool {
        guard let major = version.split(separator: ".").first.flatMap({ Int($0) }) else {
            return false
        }
        return major >= minimumGuestMajorVersion
    }

    static func unsupportedGuestMessage(version: String) -> String {
        "Automatic account creation requires a macOS 27 or later guest. The selected restore image contains macOS \(version). Choose a macOS 27 or later IPSW."
    }
}

enum VMGuestProvisioningCredentialStore {
    private static let service = "com.everettjf.ezvm.guest-provisioning"

    static func save(_ credential: VMGuestProvisioningCredential, vmRootPath: URL) -> VMOSResultVoid {
        do {
            let data = try JSONEncoder().encode(credential)
            let query = baseQuery(vmRootPath: vmRootPath)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
            if status == errSecSuccess {
                deleteLegacyItemIfNeeded(vmRootPath: vmRootPath)
                return .success
            }
            guard status == errSecItemNotFound else { return .failure(message(for: status)) }

            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { return .failure(message(for: addStatus)) }
            deleteLegacyItemIfNeeded(vmRootPath: vmRootPath)
            return .success
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
        if status == errSecItemNotFound {
            return loadLegacyItemAndMigrate(vmRootPath: vmRootPath)
        }
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
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return .failure(message(for: status))
        }
        let legacyStatus = SecItemDelete(legacyBaseQuery(vmRootPath: vmRootPath) as CFDictionary)
        return legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound
            ? .success
            : .failure(message(for: legacyStatus))
    }

    private static func baseQuery(vmRootPath: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey(vmRootPath: vmRootPath),
        ]
    }

    static func accountKey(vmRootPath: URL) -> String {
        let identifierURL = vmRootPath.appendingPathComponent("MachineIdentifier", isDirectory: false)
        if let identifier = try? Data(contentsOf: identifierURL), !identifier.isEmpty {
            return "machine:\(VMGuestAgentEnrollmentStore.machineID(machineIdentifierData: identifier))"
        }
        return legacyAccountKey(vmRootPath: vmRootPath)
    }

    static func legacyAccountKey(vmRootPath: URL) -> String {
        var path = vmRootPath.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func legacyBaseQuery(vmRootPath: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyAccountKey(vmRootPath: vmRootPath),
        ]
    }

    private static func loadLegacyItemAndMigrate(
        vmRootPath: URL
    ) -> VMOSResult<VMGuestProvisioningCredential?, String> {
        guard accountKey(vmRootPath: vmRootPath) != legacyAccountKey(vmRootPath: vmRootPath) else {
            return .success(nil)
        }
        var query = legacyBaseQuery(vmRootPath: vmRootPath)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess, let data = result as? Data else {
            return .failure(message(for: status))
        }
        do {
            let credential = try JSONDecoder().decode(VMGuestProvisioningCredential.self, from: data)
            if case .success = save(credential, vmRootPath: vmRootPath) {
                deleteLegacyItemIfNeeded(vmRootPath: vmRootPath)
            }
            return .success(credential)
        } catch {
            return .failure("The guest provisioning credential in Keychain is invalid: \(error.localizedDescription)")
        }
    }

    private static func deleteLegacyItemIfNeeded(vmRootPath: URL) {
        guard accountKey(vmRootPath: vmRootPath) != legacyAccountKey(vmRootPath: vmRootPath) else { return }
        SecItemDelete(legacyBaseQuery(vmRootPath: vmRootPath) as CFDictionary)
    }

    private static func message(for status: OSStatus) -> String {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Could not access guest provisioning credentials in Keychain: \(detail)"
    }
}

struct VMGuestProvisioningCreationCredentialTransaction {
    let vmRootPath: URL
    private(set) var isPrepared = false

    mutating func prepare(
        _ credential: VMGuestProvisioningCredential,
        save: (VMGuestProvisioningCredential, URL) -> VMOSResultVoid = {
            VMGuestProvisioningCredentialStore.save($0, vmRootPath: $1)
        }
    ) -> VMOSResultVoid {
        guard !isPrepared else {
            return .failure("Guest provisioning credentials are already prepared for this creation attempt.")
        }
        let result = save(credential, vmRootPath)
        if case .success = result { isPrepared = true }
        return result
    }

    mutating func commit() {
        // The installed VM now owns the credential until the user confirms
        // provisioning or explicitly chooses manual Setup Assistant.
        isPrepared = false
    }

    mutating func rollback(
        delete: (URL) -> VMOSResultVoid = {
            VMGuestProvisioningCredentialStore.delete(vmRootPath: $0)
        }
    ) -> VMOSResultVoid {
        guard isPrepared else { return .success }
        let result = delete(vmRootPath)
        if case .success = result { isPrepared = false }
        return result
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
    enum Compatibility: Equatable {
        case compatible
        case legacyUnverified
        case incompatible(String)
    }

    private struct Manifest: Codable, Equatable {
        struct FileIdentity: Codable, Equatable {
            let pathDigest: String
            let logicalSize: UInt64
            let modificationTime: TimeInterval
        }

        let schemaVersion: Int
        let configurationDigest: String
        let snapshotStateDigest: String?
        let hardwareModelDigest: String?
        let machineIdentifierDigest: String?
        let auxiliaryStorageDigest: String?
        let efiVariableStoreDigest: String?
        let storage: [FileIdentity]
    }

    static func pendingURL(for stateURL: URL) -> URL {
        stateURL.appendingPathExtension("pending")
    }

    static func manifestURL(for stateURL: URL) -> URL {
        stateURL.appendingPathExtension("manifest.json")
    }

    private static func pendingManifestURL(for stateURL: URL) -> URL {
        manifestURL(for: stateURL).appendingPathExtension("pending")
    }

    static func prepare(stateURL: URL) throws -> URL {
        let pending = pendingURL(for: stateURL)
        try? FileManager.default.removeItem(at: pending)
        try? FileManager.default.removeItem(at: pendingManifestURL(for: stateURL))
        return pending
    }

    static func commit(pendingURL: URL, stateURL: URL, vmRootPath: URL? = nil) throws {
        guard FileManager.default.fileExists(atPath: pendingURL.path(percentEncoded: false)) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let pendingManifest = pendingManifestURL(for: stateURL)
        if let vmRootPath {
            let manifest = try captureManifest(vmRootPath: vmRootPath)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: pendingManifest, options: .atomic)
        }
        let currentManifest = manifestURL(for: stateURL)
        if FileManager.default.fileExists(atPath: currentManifest.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: currentManifest)
        }
        if FileManager.default.fileExists(atPath: stateURL.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(stateURL, withItemAt: pendingURL)
        } else {
            try FileManager.default.moveItem(at: pendingURL, to: stateURL)
        }
        if vmRootPath != nil {
            try FileManager.default.moveItem(at: pendingManifest, to: manifestURL(for: stateURL))
        }
    }

    static func discardPending(stateURL: URL) {
        try? FileManager.default.removeItem(at: pendingURL(for: stateURL))
        try? FileManager.default.removeItem(at: pendingManifestURL(for: stateURL))
    }

    static func discardCommitted(stateURL: URL) {
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: manifestURL(for: stateURL))
        discardPending(stateURL: stateURL)
    }

    static func recoverInterruptedTransaction(stateURL: URL) {
        let pendingState = pendingURL(for: stateURL)
        let pendingManifest = pendingManifestURL(for: stateURL)
        let fm = FileManager.default
        if !fm.fileExists(atPath: pendingState.path(percentEncoded: false)),
           fm.fileExists(atPath: stateURL.path(percentEncoded: false)),
           fm.fileExists(atPath: pendingManifest.path(percentEncoded: false)) {
            try? fm.removeItem(at: manifestURL(for: stateURL))
            try? fm.moveItem(at: pendingManifest, to: manifestURL(for: stateURL))
        }
        discardPending(stateURL: stateURL)
    }

    static func compatibility(stateURL: URL, vmRootPath: URL) -> Compatibility {
        guard FileManager.default.fileExists(atPath: stateURL.path(percentEncoded: false)) else {
            return .compatible
        }
        let manifestURL = manifestURL(for: stateURL)
        guard FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)) else {
            return .legacyUnverified
        }
        do {
            let stored = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            guard stored.schemaVersion == 1 else {
                return .incompatible("Its compatibility record uses an unsupported format.")
            }
            let current = try captureManifest(vmRootPath: vmRootPath)
            guard stored.configurationDigest == current.configurationDigest else {
                return .incompatible("The virtual machine configuration changed after its state was saved.")
            }
            guard stored.snapshotStateDigest == current.snapshotStateDigest else {
                return .incompatible("The active disk snapshot branch changed after its state was saved.")
            }
            guard stored.hardwareModelDigest == current.hardwareModelDigest,
                  stored.machineIdentifierDigest == current.machineIdentifierDigest,
                  stored.auxiliaryStorageDigest == current.auxiliaryStorageDigest,
                  stored.efiVariableStoreDigest == current.efiVariableStoreDigest else {
                return .incompatible("The virtual machine hardware identity changed after its state was saved.")
            }
            guard stored.storage == current.storage else {
                return .incompatible("One or more virtual disks changed after the machine state was saved.")
            }
            return .compatible
        } catch {
            return .incompatible("Its compatibility record is damaged or incomplete.")
        }
    }

    static func coldBootNotice(reason: String) -> String {
        "EZVM could not safely resume the saved session because \(reason). " +
        "The saved session was discarded and the virtual machine is starting normally."
    }

    private static func captureManifest(vmRootPath: URL) throws -> Manifest {
        let configURL = vmRootPath.appending(path: "config.json")
        let configData = try Data(contentsOf: configURL)
        guard let configObject = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let storageDevices = configObject["storageDevices"] as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let snapshotStateURL = VMSnapshotManager.snapshotsRootURL(vmRootPath: vmRootPath)
            .appending(path: "state.json")
        let snapshotStateData: Data?
        if FileManager.default.fileExists(atPath: snapshotStateURL.path(percentEncoded: false)) {
            snapshotStateData = try Data(contentsOf: snapshotStateURL)
        } else {
            snapshotStateData = nil
        }
        var storageURLs = try storageDevices.map { device -> URL in
            guard let imagePath = device["imagePath"] as? String,
                  let type = device["type"] as? String else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if type == "USB", imagePath.hasPrefix("/") {
                return URL(filePath: imagePath).standardizedFileURL
            }
            return vmRootPath.appending(path: imagePath).standardizedFileURL
        }
        if let snapshotStateData {
            guard let object = try JSONSerialization.jsonObject(with: snapshotStateData) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if let value = object["activeDiskLayers"] {
                guard let active = value as? [String: [String]] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                storageURLs.append(contentsOf: active.values.flatMap { $0 }.map {
                    vmRootPath.appending(path: $0).standardizedFileURL
                })
            }
        }
        let storage = try Array(Set(storageURLs.map { $0.path(percentEncoded: false) })).sorted().map { path in
            let url = URL(filePath: path).standardizedFileURL
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = values.fileSize, let modified = values.contentModificationDate else {
                throw CocoaError(.fileReadUnknown)
            }
            return Manifest.FileIdentity(
                pathDigest: digest(Data(path.utf8)),
                logicalSize: UInt64(size),
                modificationTime: modified.timeIntervalSince1970
            )
        }
        return Manifest(
            schemaVersion: 1,
            configurationDigest: try canonicalJSONDigest(configData),
            snapshotStateDigest: try snapshotStateData.map(canonicalJSONDigest),
            hardwareModelDigest: try digestIfPresent(vmRootPath.appending(path: "HardwareModel")),
            machineIdentifierDigest: try digestIfPresent(vmRootPath.appending(path: "MachineIdentifier")),
            auxiliaryStorageDigest: try digestIfPresent(vmRootPath.appending(path: "AuxiliaryStorage")),
            efiVariableStoreDigest: try digestIfPresent(vmRootPath.appending(path: "NVRAM")),
            storage: storage
        )
    }

    private static func digestIfPresent(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return digest(try Data(contentsOf: url))
    }

    private static func canonicalJSONDigest(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return digest(canonical)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

struct VMNetworkDeviceIssue: Equatable, Identifiable {
    let deviceIndex: Int
    let reason: String

    var id: Int { deviceIndex }
    var title: String { "Network Adapter \(deviceIndex + 1)" }
}

enum VMNetworkFailureGuidance {
    static let maximumFrameworkDetailCharacters = 160

    static func disconnectReason(frameworkDescription: String) -> String {
        let base = "The host disconnected this network adapter. Check the selected interface, VPN, and network access, then reconnect."
        let visibleScalars = frameworkDescription.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                || CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let normalized = String(String.UnicodeScalarView(visibleScalars))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return base }
        let detail = String(normalized.prefix(maximumFrameworkDetailCharacters))
        return "\(base) Framework detail: \(detail)"
    }
}

enum VMNetworkRuntimeState: Equatable {
    case unavailable
    case preparing(deviceCount: Int)
    case connected(deviceCount: Int)
    case hostSleeping(deviceCount: Int)
    case reconnecting(deviceCount: Int, issues: [VMNetworkDeviceIssue], deviceIndices: [Int])
    case degraded(deviceCount: Int, issues: [VMNetworkDeviceIssue])

    var issues: [VMNetworkDeviceIssue] {
        switch self {
        case .reconnecting(_, let issues, _), .degraded(_, let issues): issues
        default: []
        }
    }

    var reconnectingDeviceIndices: Set<Int> {
        guard case .reconnecting(_, _, let deviceIndices) = self else { return [] }
        return Set(deviceIndices)
    }
}

enum VMNetworkWakeRecoveryFence {
    static func begin(currentToken: inout UUID?) -> UUID {
        let token = UUID()
        currentToken = token
        return token
    }

    static func invalidate(currentToken: inout UUID?) {
        currentToken = nil
    }

    static func shouldRun(
        token: UUID,
        currentToken: UUID?,
        isHostSleeping: Bool
    ) -> Bool {
        currentToken == token && !isHostSleeping
    }
}

struct VMNetworkRuntimeTracker: Equatable {
    static let automaticReconnectDelays: [TimeInterval] = [1, 3]
    static let reconnectAcceptanceDelay: TimeInterval = 0.25
    static let reconnectStabilizationDelay: TimeInterval = 3

    private(set) var deviceCount: Int
    private(set) var isStarted = false
    private(set) var isHostSleeping = false
    private(set) var disconnectedReasons: [Int: String] = [:]
    private(set) var reconnectingIndices = Set<Int>()
    private(set) var stabilizingIndices = Set<Int>()
    private(set) var automaticReconnectAttempts: [Int: Int] = [:]

    var disconnectedDeviceIndices: [Int] { disconnectedReasons.keys.sorted() }

    init(deviceCount: Int) {
        self.deviceCount = max(deviceCount, 0)
    }

    var state: VMNetworkRuntimeState {
        guard deviceCount > 0 else { return .unavailable }
        let issues = disconnectedReasons
            .map { VMNetworkDeviceIssue(deviceIndex: $0.key, reason: $0.value) }
            .sorted { $0.deviceIndex < $1.deviceIndex }
        guard isStarted else { return .preparing(deviceCount: deviceCount) }
        if isHostSleeping { return .hostSleeping(deviceCount: deviceCount) }
        let recoveringIndices = reconnectingIndices.union(stabilizingIndices)
        if !recoveringIndices.isEmpty {
            return .reconnecting(
                deviceCount: deviceCount,
                issues: issues,
                deviceIndices: recoveringIndices.sorted()
            )
        }
        return issues.isEmpty
            ? .connected(deviceCount: deviceCount)
            : .degraded(deviceCount: deviceCount, issues: issues)
    }

    mutating func markStarted() {
        isStarted = true
    }

    mutating func markDisconnected(deviceIndex: Int, reason: String) {
        guard (0..<deviceCount).contains(deviceIndex) else { return }
        disconnectedReasons[deviceIndex] = reason
        reconnectingIndices.remove(deviceIndex)
        stabilizingIndices.remove(deviceIndex)
    }

    mutating func beginReconnect(deviceIndex: Int) -> Bool {
        guard isStarted,
              !isHostSleeping,
              disconnectedReasons[deviceIndex] != nil,
              !reconnectingIndices.contains(deviceIndex),
              !stabilizingIndices.contains(deviceIndex) else { return false }
        reconnectingIndices.insert(deviceIndex)
        return true
    }

    mutating func markReconnectRequestAccepted(deviceIndex: Int) -> Bool {
        guard disconnectedReasons[deviceIndex] != nil,
              reconnectingIndices.remove(deviceIndex) != nil else { return false }
        stabilizingIndices.insert(deviceIndex)
        return true
    }

    mutating func markConnected(deviceIndex: Int) {
        guard (0..<deviceCount).contains(deviceIndex) else { return }
        disconnectedReasons.removeValue(forKey: deviceIndex)
        reconnectingIndices.remove(deviceIndex)
        stabilizingIndices.remove(deviceIndex)
        automaticReconnectAttempts.removeValue(forKey: deviceIndex)
    }

    mutating func beginAutomaticReconnect(deviceIndex: Int) -> TimeInterval? {
        guard isStarted,
              !isHostSleeping,
              disconnectedReasons[deviceIndex] != nil,
              !reconnectingIndices.contains(deviceIndex),
              !stabilizingIndices.contains(deviceIndex) else { return nil }
        let attempt = automaticReconnectAttempts[deviceIndex, default: 0]
        guard Self.automaticReconnectDelays.indices.contains(attempt) else { return nil }
        automaticReconnectAttempts[deviceIndex] = attempt + 1
        reconnectingIndices.insert(deviceIndex)
        return Self.automaticReconnectDelays[attempt]
    }

    mutating func resetAutomaticReconnectAttempts(deviceIndex: Int) {
        automaticReconnectAttempts.removeValue(forKey: deviceIndex)
    }

    mutating func markHostSleeping() {
        guard deviceCount > 0 else { return }
        isHostSleeping = true
        reconnectingIndices.removeAll()
        stabilizingIndices.removeAll()
        automaticReconnectAttempts.removeAll()
    }

    @discardableResult
    mutating func markHostAwake() -> [Int] {
        isHostSleeping = false
        automaticReconnectAttempts.removeAll()
        return disconnectedDeviceIndices
    }
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
    static let defaultReserveBytes: Int64 = 1_073_741_824

    static func availableBytes(at url: URL) -> Int64? {
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        return (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    static func validate(
        requiredBytes: Int64?,
        at url: URL,
        reserveBytes: Int64 = defaultReserveBytes,
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

struct VMSharedFolderRuntimeEntry: Equatable {
    let name: String
    let path: URL
    let readOnly: Bool
}

enum VMSharedFolderRuntimePlan {
    static func uniquelyNamed(_ entries: [VMSharedFolderRuntimeEntry]) -> [VMSharedFolderRuntimeEntry] {
        var used: Set<String> = []
        return entries.map { entry in
            var name = entry.name
            var suffix = 2
            while used.contains(name) {
                name = "\(entry.name) \(suffix)"
                suffix += 1
            }
            used.insert(name)
            return VMSharedFolderRuntimeEntry(name: name, path: entry.path, readOnly: entry.readOnly)
        }
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
