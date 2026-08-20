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

class VMOSHelper {
    
    // Create an empty disk image for the Virtual Machine.
    static func createEmptyDiskImage(filePath: URL, size: UInt64) -> VMOSResultVoid {
        let diskFd = open(filePath.path(percentEncoded: false), O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        if diskFd == -1 {
            return .failure("Cannot create disk image.")
        }
        
        var result = ftruncate(diskFd, off_t(size))
        if result != 0 {
            return .failure("ftruncate() failed.")
        }
        
        result = close(diskFd)
        if result != 0 {
            return .failure("Failed to close the disk image.")
        }
        return .success
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
