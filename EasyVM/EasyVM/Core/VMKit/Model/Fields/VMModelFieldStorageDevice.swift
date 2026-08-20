//
//  VMModelFieldStorageDevice.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation
import Virtualization

#if arch(arm64)
struct VMModelFieldStorageDevice : Decodable, Encodable, CustomStringConvertible {
    enum DeviceType : String, CaseIterable, Identifiable, Decodable, Encodable {
        case Block, USB
        var id: Self { self }
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
        // EasyVM 3.2.x and earlier only created raw disk images.
        format = try container.decodeIfPresent(VMDiskImageFormat.self, forKey: .format) ?? .raw
    }
    
    var description: String {
        if type == .Block {
            return "\(type) \(format.rawValue.uppercased()) \(size / 1024 / 1024 / 1024)GB"
        } else {
            return "\(type) \(imagePath)"
        }
    }
    
    
    var shortDescription: String {
        if type == .Block {
            return "\(type) \(format.rawValue.uppercased()) \(size / 1024 / 1024 / 1024)GB"
        } else {
            return "\(type)"
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
        // TODO: get host disk left size
        return 10 * 1024 * 1024 * 1024 * 1024
    }
    
    static func `default`() -> VMModelFieldStorageDevice {
        return VMModelFieldStorageDevice(type: .Block, size: Self.defaultDiskSize(), imagePath: "Disk.asif", format: .asif)
    }
    
    func createConfiguration(rootPath: URL) -> VMOSResult<VZStorageDeviceConfiguration, String> {
        if self.type == .USB {
            guard let diskImageAttachment = try? VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: imagePath), readOnly: false) else {
                return .failure("Failed to create Disk image.")
            }
            
            let disk = VZUSBMassStorageDeviceConfiguration(attachment: diskImageAttachment)
            return .success(disk)
        }
        
        // create disk
        let fullPath = rootPath.appending(path: imagePath)
        let createResult = VMDiskImageManager.create(format: format, at: fullPath, size: size)
        if case let .failure(error) = createResult {
            return .failure(error)
        }
        
        // attachment
        guard let diskImageAttachment = try? VZDiskImageStorageDeviceAttachment(url: fullPath, readOnly: false) else {
            return .failure("Failed to create Disk image.")
        }
        let disk = VZVirtioBlockDeviceConfiguration(attachment: diskImageAttachment)
        return .success(disk)
    }
}

#endif
