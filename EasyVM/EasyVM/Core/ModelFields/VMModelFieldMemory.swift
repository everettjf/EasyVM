//
//  VMModelFieldMemory.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation
import SwiftUI
import Virtualization

struct VMModelFieldMemory: Decodable {
    let size: UInt64
    
    static func `default`() -> VMModelFieldMemory {
        return VMModelFieldMemory(size: Self.defaultSize())
    }
    
    static func defaultSize() -> UInt64 {
        // We arbitrarily choose 4GB.
        var memorySize = (4 * 1024 * 1024 * 1024) as UInt64
        memorySize = Swift.max(memorySize, Self.minSize())
        memorySize = Swift.min(memorySize, Self.maxSize())

        return memorySize
    }
    
    static func maxSize() -> UInt64 {
        return VZVirtualMachineConfiguration.maximumAllowedMemorySize
    }
    
    static func minSize() -> UInt64 {
        return VZVirtualMachineConfiguration.minimumAllowedMemorySize
    }
}
