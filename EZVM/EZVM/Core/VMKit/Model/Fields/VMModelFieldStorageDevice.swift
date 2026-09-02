//
//  VMModelFieldStorageDevice.swift
//  EZVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation
import Virtualization
#if canImport(DiskImageKit)
import DiskImageKit
#endif

#if arch(arm64)
struct VMModelFieldStorageDevice : Decodable, Encodable, CustomStringConvertible {
    enum DeviceType : String, CaseIterable, Identifiable, Decodable, Encodable {
        case Block, USB
        var id: Self { self }

        var displayName: String {
            switch self {
            case .Block: "Virtual Disk"
            case .USB: "Installation Media"
            }
        }
    }
    
    let type: DeviceType
    let size: UInt64
    let format: VMDiskImageFormat
    
    /*
     - file name only when .Block
     - full path when .USB
     */
    let imagePath: String

    init(type: DeviceType, size: UInt64, imagePath: String, format: VMDiskImageFormat = .raw) {
        self.type = type
        self.size = size
        self.imagePath = imagePath
        self.format = format
    }

    private enum CodingKeys: String, CodingKey {
        case type, size, imagePath, format
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(DeviceType.self, forKey: .type)
        size = try container.decode(UInt64.self, forKey: .size)
        imagePath = try container.decode(String.self, forKey: .imagePath)
        // EZVM 3.2.x and earlier only created raw disk images.
        format = try container.decodeIfPresent(VMDiskImageFormat.self, forKey: .format) ?? .raw
    }
    
    var description: String {
        if type == .Block {
            return "\(type.displayName) · \(format.rawValue.uppercased()) · \(size / 1024 / 1024 / 1024) GB"
        } else {
            return "\(type.displayName) · \(URL(fileURLWithPath: imagePath).lastPathComponent)"
        }
    }
    
    
    var shortDescription: String {
        if type == .Block {
            return "\(type.displayName) · \(format.rawValue.uppercased()) · \(size / 1024 / 1024 / 1024) GB"
        } else {
            return type.displayName
        }
    }
    
    static func defaultDiskSize() -> UInt64 {
        // 64GB
        return 64 * 1024 * 1024 * 1024
    }
    
    static func minDiskSize() -> UInt64 {
        return 10 * 1024 * 1024 * 1024
    }
    
    static func maxDiskSize() -> UInt64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let available = VMStorageCapacity.availableBytes(at: home) ?? Int64(defaultDiskSize())
        let reserve = Int64(5 * 1024 * 1024 * 1024)
        return UInt64(max(Int64(defaultDiskSize()), available - reserve))
    }
    
    static func `default`() -> VMModelFieldStorageDevice {
        return VMModelFieldStorageDevice(type: .Block, size: Self.defaultDiskSize(), imagePath: "Disk.asif", format: .asif)
    }
    
    func createConfiguration(rootPath: URL) -> VMOSResult<VZStorageDeviceConfiguration, String> {
        if self.type == .USB {
            // The UI exposes USB-backed storage as ISO installation media.
            // Opening it read-only lets multiple VMs safely share the same ISO
            // and prevents a guest from mutating the host's installer image.
            guard let diskImageAttachment = try? VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: imagePath), readOnly: true) else {
                return .failure("Failed to create Disk image.")
            }
            
            let disk = VZUSBMassStorageDeviceConfiguration(attachment: diskImageAttachment)
            return .success(disk)
        }
        
        // create disk
        let fullPath = rootPath.appending(path: imagePath)
        if format == .asif,
           case let .failure(error) = VMSnapshotManager.validateExistingASIFBaseDependency(
               baseURL: fullPath,
               vmRootPath: rootPath
           ) {
            return .failure(error)
        }
        let createResult = VMDiskImageManager.create(format: format, at: fullPath, size: size)
        if case let .failure(error) = createResult {
            return .failure(error)
        }
        
        // ASIF disks automatically use DiskImageKit overlay stacks. Existing
        // raw-image machines stay on their original URL attachment path.
        let diskImageAttachment: VZDiskImageStorageDeviceAttachment
#if canImport(DiskImageKit)
        if #available(macOS 27.0, *), format == .asif {
            do {
                if let layeredImage = try VMSnapshotManager.layeredDiskImage(baseURL: fullPath, vmRootPath: rootPath) {
                    diskImageAttachment = try VZDiskImageStorageDeviceAttachment(diskImage: layeredImage)
                } else {
                    diskImageAttachment = try VZDiskImageStorageDeviceAttachment(url: fullPath, readOnly: false)
                }
            } catch {
                return .failure("Failed to open the DiskImageKit layer stack: \(error.localizedDescription)")
            }
        } else {
            guard let attachment = try? VZDiskImageStorageDeviceAttachment(url: fullPath, readOnly: false) else {
                return .failure("Failed to create disk image attachment.")
            }
            diskImageAttachment = attachment
        }
#else
        guard let attachment = try? VZDiskImageStorageDeviceAttachment(url: fullPath, readOnly: false) else {
            return .failure("Failed to create disk image attachment.")
        }
        diskImageAttachment = attachment
#endif
        let disk = VZVirtioBlockDeviceConfiguration(attachment: diskImageAttachment)
        return .success(disk)
    }
}

#endif
