//
//  VMModelFieldStorageDevice.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation
import Virtualization

struct VMModelFieldStorageDevice : Decodable, CustomStringConvertible {
    enum DeviceType : String, CaseIterable, Identifiable, Decodable {
        case Block, USB
        var id: Self { self }
    }
    
    let type: DeviceType
    let size: UInt64?
    let imagePath: String?
    
    var description: String {
        if type == .Block {
            return "\(type) \(size! / 1024 / 1024 / 1024)GB"
        } else {
            return "\(type) \(imagePath!)"
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
    
    static func `default`(location: VMLocationModel) -> VMModelFieldStorageDevice {
        return VMModelFieldStorageDevice(type: .Block, size: Self.defaultDiskSize(), imagePath: location.getMainDiskImage())
    }
}
