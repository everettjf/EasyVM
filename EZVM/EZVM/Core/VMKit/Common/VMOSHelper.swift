//
//  VMOSHelper.swift
//  EZVM
//
//  Created by everettjf on 2022/10/1.
//

import Foundation
import Security
import Virtualization


#if arch(arm64)
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
        // Six vCPUs are ample for an interactive Linux desktop while leaving
        // enough scheduling capacity for macOS on smaller Apple silicon Macs.
        let availableCPUCount = max(hostCPUCount - 2, minimumCPUCount)
        let cpuCount = min(max(availableCPUCount, minimumCPUCount), min(6, maximumCPUCount))

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
    let requireKVM: Bool
    let guestAgentEnrollmentURL: URL?
}

enum VMReleaseSmokeTest {
    static let vmPathEnvironmentKey = "EZVM_RELEASE_SMOKE_VM"
    static let resultPathEnvironmentKey = "EZVM_RELEASE_SMOKE_RESULT"
    static let processIDPathEnvironmentKey = "EZVM_RELEASE_SMOKE_PID"
    static let requireGuestAgentEnvironmentKey = "EZVM_RELEASE_REQUIRE_GUEST_AGENT"
    static let requireGuestInputEnvironmentKey = "EZVM_RELEASE_REQUIRE_GUEST_INPUT"
    static let requireKVMEnvironmentKey = "EZVM_RELEASE_REQUIRE_KVM"
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
            requireKVM: environment[requireKVMEnvironmentKey] == "1",
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
        }
    }

    var minimumMajorVersion: Int {
        switch self {
        case .savedState, .automaticDisplayResize: 14
        case .asifStorage: 26
        case .guestProvisioning, .diskImageKitSnapshots, .customVirtio, .efiSecureBoot: 27
        }
    }

    var isAvailable: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: minimumMajorVersion, minorVersion: 0, patchVersion: 0)
        )
    }
}

enum EZVMExperimentalFeatures {
    static let guestProvisioningKey = "experimental.guestProvisioning"
    static let diskImageKitSnapshotsKey = "experimental.diskImageKitSnapshots"
    static let efiSecureBootKey = "experimental.efiSecureBoot"
    static let customVirGLGraphicsKey = "experimental.customVirGLGraphics"
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
        customBackendImplemented: Bool
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
}

struct VMGuestProvisioningCredential: Codable, Equatable {
    let fullName: String
    let username: String
    let password: String
    let logsInAutomatically: Bool
    let enablesRemoteLogin: Bool
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

    static func delete(vmRootPath: URL) {
        SecItemDelete(baseQuery(vmRootPath: vmRootPath) as CFDictionary)
    }

    private static func baseQuery(vmRootPath: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vmRootPath.standardizedFileURL.path(percentEncoded: false),
        ]
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
        return convertRawToASIF(sourceURL: sourceURL, destinationURL: destinationURL, executor: run)
    }

    static func convertRawToASIF(
        sourceURL: URL,
        destinationURL: URL,
        executor: (Command) -> VMOSResultVoid
    ) -> VMOSResultVoid {
        guard FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
            return .failure("The source disk image does not exist.")
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) else {
            return .failure("The destination disk image already exists.")
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

    static func validate(requiredBytes: Int64?, at url: URL, reserveBytes: Int64 = 1_073_741_824) throws {
        guard let requiredBytes, requiredBytes > 0,
              let available = availableBytes(at: url),
              available < requiredBytes + reserveBytes else { return }
        throw VMDownloadValidationError.insufficientDiskSpace(required: requiredBytes + reserveBytes, available: available)
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
}

#endif
