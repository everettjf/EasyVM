//
//  VMModelFieldCPU.swift
//  EZVM
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
        VMCPUResourceRecommendation.recommended(
            hostCPUCount: ProcessInfo.processInfo.processorCount,
            minimumCPUCount: Self.minCount(),
            maximumCPUCount: Self.maxCount()
        )
    }
    
    static func maxCount() -> Int {
        return VZVirtualMachineConfiguration.maximumAllowedCPUCount
    }
    
    static func minCount() -> Int {
        return VZVirtualMachineConfiguration.minimumAllowedCPUCount
    }

}


#endif
