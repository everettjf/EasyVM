//
//  VMModelBuilder.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/19.
//

import Foundation
import SwiftUI


class VMModelBuilder {
    
    
    static func buildDefaultModel(location: VMLocationModel) -> VMModel {
        let name = "My Virtual Machine"

        
        
        
        let config = VMConfigModel(type: .macOS, name: name, remark: nil, cpuCount: <#T##UInt32#>, memorySize: <#T##UInt64#>, diskSize: <#T##UInt64#>, graphicsDevices: <#T##[VMGraphicDeviceModel]#>, storageDevices: <#T##[VMStorageDeviceModel]#>, networkDevices: <#T##[VMNetworkDeviceModel]#>, pointingDevices: <#T##[VMPointingDeviceModel]#>, keyboardDevices: <#T##[VMKeyboardDeviceModel]#>, audioDevices: <#T##[VMAudioDeviceModel]#>)
        
        
        return VMModel(location: location, config: config)
    }
}
