//
//  VMModelFieldCPU.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/22.
//

import Foundation
import SwiftUI
import Virtualization


#if arch(arm64)
struct VMModelFieldCPU: Decodable, Encodable {
    let count: Int
    
    static func `default`() -> VMModelFieldCPU {
        return VMModelFieldCPU(count: Self.defaultCount())
    }
    
    static func defaultCount() -> Int {
        let totalAvailableCPUs = ProcessInfo.processInfo.processorCount
        var virtualCPUCount = totalAvailableCPUs <= 1 ? 1 : totalAvailableCPUs - 1
        virtualCPUCount = Swift.max(virtualCPUCount, Self.minCount())
        virtualCPUCount = Swift.min(virtualCPUCount, Self.maxCount())
        return virtualCPUCount
    }
    
    static func maxCount() -> Int {
        return VZVirtualMachineConfiguration.maximumAllowedCPUCount
    }
    
    static func minCount() -> Int {
        return VZVirtualMachineConfiguration.minimumAllowedCPUCount
    }

}


#endif
