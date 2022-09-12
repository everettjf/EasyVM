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

        let cpu = VMModelFieldCPU.default()
        let memory = VMModelFieldMemory.default()
        let graphicDevice = VMModelFieldGraphicDevice.default()
        let storageDevice = VMModelFieldStorageDevice.default(location: location)
        let networkDevice = VMModelFieldNetworkDevice.default()
        let pointingDevice = VMModelFieldPointingDevice.default()
        let keyboardDevice = VMModelFieldKeyboardDevice.default()
        let audioDevices = VMModelFieldAudioDevice.defaults()
        
        let config = VMConfigModel(type: .macOS, name: name, remark: nil, cpu: cpu, memory: memory, graphicsDevices: [graphicDevice], storageDevices: [storageDevice], networkDevices: [networkDevice], pointingDevices: [pointingDevice], keyboardDevices: [keyboardDevice], audioDevices: audioDevices)
        
        return VMModel(location: location, config: config)
    }
}
