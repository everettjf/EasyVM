//
//  VMModelFieldStorageDevice.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation
import Virtualization

struct VMModelFieldStorageDevice : Decodable, Encodable, CustomStringConvertible {
    enum DeviceType : String, CaseIterable, Identifiable, Decodable, Encodable {
        case Block, USB
        var id: Self { self }
    }
    
    let type: DeviceType
    let size: UInt64
    
    /*
     - file name only when .Block
     - full path when .USB
     */
    let imagePath: String
    
    var description: String {
        if type == .Block {
            return "\(type) \(size / 1024 / 1024 / 1024)GB"
        } else {
            return "\(type) \(imagePath)"
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
        return VMModelFieldStorageDevice(type: .Block, size: Self.defaultDiskSize(), imagePath: "Disk.img")
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
        let createResult = VMOSHelper.createEmptyDiskImage(filePath: fullPath, size: size)
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
