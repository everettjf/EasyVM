//
//  VMOSHelper.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/1.
//

import Foundation


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

#endif
