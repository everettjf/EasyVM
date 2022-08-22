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

        let cpuCount = VMModelHelper_CPU.defaultCount()
        let memorySize = VMModelHelper_Memory.defaultSize()
        let graphicDevice = VMModelHelper_GraphicsDevice.defaultModel()
        let storageDevice = VMModelHelper_Storage.defaultModel(location: location)
        let networkDevice = VMModelHelper_Network.defaultModel()
        let pointingDevice = VMModelHelper_PointingDevice.defaultModel()
        let keyboardDevice = VMKeyboardDeviceModel.defaultModel()
        let audioDevices = VMAudioDeviceModel.defaultModels()
        
        let config = VMConfigModel(type: .macOS, name: name, remark: nil, cpuCount: cpuCount, memorySize: memorySize, graphicsDevices: [graphicDevice], storageDevices: [storageDevice], networkDevices: [networkDevice], pointingDevices: [pointingDevice], keyboardDevices: [keyboardDevice], audioDevices: audioDevices)
        
        return VMModel(location: location, config: config)
    }
}
