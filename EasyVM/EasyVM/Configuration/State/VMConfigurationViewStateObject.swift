//
//  VMConfigurationViewState.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/29.
//

import Foundation
import SwiftUI

struct VMModelFieldGraphicDeviceItemModel: Identifiable {
    let id = UUID()
    let data: VMModelFieldGraphicDevice
}

struct VMModelFieldStorageDeviceItemModel: Identifiable {
    let id = UUID()
    let data: VMModelFieldStorageDevice
}

struct VMModelFieldNetworkDeviceItemModel: Identifiable {
    let id = UUID()
    let data: VMModelFieldNetworkDevice
}

struct VMModelFieldPointingDeviceItemModel: Identifiable {
    let id = UUID()
    let data: VMModelFieldPointingDevice
}

struct VMModelFieldAudioDeviceItemModel: Identifiable {
    let id = UUID()
    let data: VMModelFieldAudioDevice
}



class VMConfigurationViewStateObject: ObservableObject {
    @Published var osType: VMOSType = .macOS
    
    @Published var name: String = ""
    @Published var remark: String = ""
    
    @Published var cpuCount: Int = 1
    @Published var memorySize: UInt64 = 1024 * 1024 * 1024 * 4

    @Published var graphicDevices: [VMModelFieldGraphicDeviceItemModel] = []
    @Published var storageDevices: [VMModelFieldStorageDeviceItemModel] = []
    @Published var networkDevices: [VMModelFieldNetworkDeviceItemModel] = []
    
    @Published var pointingDevices: [VMModelFieldPointingDeviceItemModel] = []
    @Published var audioDevices: [VMModelFieldAudioDeviceItemModel] = []
    
    convenience init() {
        // default
        self.init(configModel: VMConfigModel.create(osType: .macOS,name: "", remark: ""))
    }

    init(configModel: VMConfigModel) {
        self.osType = configModel.type
        self.name = configModel.name
        self.remark = configModel.remark
        
        self.cpuCount = configModel.cpu.count
        self.memorySize = configModel.memory.size
        
        for item in configModel.storageDevices {
            self.storageDevices.append(VMModelFieldStorageDeviceItemModel(data: item))
        }
        for item in configModel.graphicsDevices {
            self.graphicDevices.append(VMModelFieldGraphicDeviceItemModel(data: item))
        }
        for item in configModel.networkDevices {
            self.networkDevices.append(VMModelFieldNetworkDeviceItemModel(data: item))
        }
        for item in configModel.pointingDevices {
            self.pointingDevices.append(VMModelFieldPointingDeviceItemModel(data: item))
        }
        for item in configModel.audioDevices {
            self.audioDevices.append(VMModelFieldAudioDeviceItemModel(data: item))
        }
    }
    
    func getConfigModel() -> VMConfigModel {
        
        let cpu = VMModelFieldCPU(count: self.cpuCount)
        let memory = VMModelFieldMemory(size: self.memorySize)
        let graphicDevices = self.graphicDevices.map({$0.data})
        let storageDevices = self.storageDevices.map({$0.data})
        let networkDevices = self.networkDevices.map({$0.data})
        let pointingDevices = self.pointingDevices.map({$0.data})
        let audioDevices = self.audioDevices.map({$0.data})
        
        return VMConfigModel(type: osType, name: name, remark: remark, cpu: cpu, memory: memory, graphicsDevices: graphicDevices, storageDevices: storageDevices, networkDevices: networkDevices, pointingDevices: pointingDevices, audioDevices: audioDevices)
    }
    
}
