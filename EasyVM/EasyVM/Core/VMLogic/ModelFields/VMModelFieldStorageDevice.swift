//
//  VMModelFieldStorageDevice.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation
import Virtualization

struct VMModelFieldStorageDevice : Decodable {
    let type: String
    let size: UInt64?
    let imagePath: String?
    
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
        return VMModelFieldStorageDevice(type: "disk", size: Self.defaultDiskSize(), imagePath: location.getMainDiskImage())
    }
}
