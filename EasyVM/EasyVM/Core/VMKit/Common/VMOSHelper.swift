//
//  VMOSHelper.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/1.
//

import Foundation
import Security
import Virtualization


#if arch(arm64)
struct VMReleaseSmokeTestConfiguration: Equatable {
    let vmRootPath: URL
    let resultPath: URL
}

enum VMReleaseSmokeTest {
    static let vmPathEnvironmentKey = "EASYVM_RELEASE_SMOKE_VM"
    static let resultPathEnvironmentKey = "EASYVM_RELEASE_SMOKE_RESULT"

    static func configuration(environment: [String: String] = ProcessInfo.processInfo.environment) -> VMReleaseSmokeTestConfiguration? {
        guard let vmPath = environment[vmPathEnvironmentKey], !vmPath.isEmpty,
              let resultPath = environment[resultPathEnvironmentKey], !resultPath.isEmpty else {
            return nil
        }
        return VMReleaseSmokeTestConfiguration(
            vmRootPath: URL(filePath: vmPath).standardizedFileURL,
            resultPath: URL(filePath: resultPath).standardizedFileURL
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

enum EasyVMExperimentalFeatures {
    static let guestProvisioningKey = "experimental.guestProvisioning"
    static let diskImageKitSnapshotsKey = "experimental.diskImageKitSnapshots"
    static let customVirtioKey = "experimental.customVirtio"
    static let efiSecureBootKey = "experimental.efiSecureBoot"
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
    private static let service = "com.everettjf.easyvm.guest-provisioning"

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
            guard format == .raw,
                  let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  UInt64(fileSize) == size else {
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

#endif
