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
enum VirtualizationCapability: String, CaseIterable, Identifiable {
    case savedState, automaticDisplayResize, asifStorage, advancedNetworking
    case guestProvisioning, diskImageKitSnapshots, usbPassthrough, customVirtio, efiSecureBoot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .savedState: "Saved machine state"
        case .automaticDisplayResize: "Automatic display resizing"
        case .asifStorage: "ASIF storage"
        case .advancedNetworking: "Advanced networking"
        case .guestProvisioning: "macOS guest provisioning"
        case .diskImageKitSnapshots: "DiskImageKit snapshots"
        case .usbPassthrough: "USB passthrough"
        case .customVirtio: "Custom Virtio devices"
        case .efiSecureBoot: "EFI Secure Boot management"
        }
    }

    var minimumMajorVersion: Int {
        switch self {
        case .savedState, .automaticDisplayResize: 14
        case .asifStorage, .advancedNetworking: 26
        case .guestProvisioning, .diskImageKitSnapshots, .usbPassthrough, .customVirtio, .efiSecureBoot: 27
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
    static let usbPassthroughKey = "experimental.usbPassthrough"
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

    static let legacy = VMLinuxFeatureConfiguration(
        rosettaEnabled: false,
        rosettaCachingEnabled: false,
        memoryBalloonEnabled: false,
        entropyEnabled: false,
        virtioSocketEnabled: false,
        secureBootEnabled: false
    )

    static let recommended = VMLinuxFeatureConfiguration(
        rosettaEnabled: false,
        rosettaCachingEnabled: true,
        memoryBalloonEnabled: true,
        entropyEnabled: true,
        virtioSocketEnabled: true,
        secureBootEnabled: false
    )
}

extension VMLinuxFeatureConfiguration {
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

struct VMUSBDeviceDescriptor: Equatable {
    let vendorID: UInt16
    let productID: UInt16
    let deviceClass: UInt8

    init?(data: Data) {
        guard data.count >= 12, data[0] >= 12, data[1] == 1 else { return nil }
        vendorID = UInt16(data[8]) | UInt16(data[9]) << 8
        productID = UInt16(data[10]) | UInt16(data[11]) << 8
        deviceClass = data[4]
    }

    var name: String {
        switch deviceClass {
        case 1: "USB Audio"
        case 2: "USB Communications"
        case 3: "USB Human Interface"
        case 7: "USB Printer"
        case 8: "USB Storage"
        case 9: "USB Hub"
        case 14: "USB Video"
        case 224: "USB Wireless Controller"
        default: "USB Accessory"
        }
    }

    var identifier: String { String(format: "%04X:%04X", vendorID, productID) }
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
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return .success
        }

        switch format {
        case .raw:
            return createRaw(at: url, size: size)
        case .asif:
            guard let command = creationCommand(format: format, url: url, size: size) else {
                return .failure("Could not prepare the ASIF creation command.")
            }
            return run(command)
        }
    }

    static func convertRawToASIF(sourceURL: URL, destinationURL: URL) -> VMOSResultVoid {
        guard FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
            return .failure("The source disk image does not exist.")
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) else {
            return .failure("The destination disk image already exists.")
        }
        return run(conversionCommand(sourceURL: sourceURL, destinationURL: destinationURL))
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

#endif
