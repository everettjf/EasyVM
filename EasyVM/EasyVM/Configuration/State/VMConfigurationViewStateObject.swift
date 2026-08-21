//
//  VMConfigurationViewState.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/29.
//

import Foundation
import SwiftUI
import Observation


#if arch(arm64)
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

struct VMModelFieldDirectorySharingDeviceItemModel: Identifiable {
    let id = UUID()
    let data: VMModelFieldDirectorySharingDevice
}


@MainActor
@Observable
class VMConfigurationViewStateObject {
    var osType: VMOSType = .macOS
    
    var name: String = ""
    var remark: String = ""
    
    var cpuCount: Int = 1
    var memorySize: UInt64 = 1024 * 1024 * 1024 * 4

    var graphicDevices: [VMModelFieldGraphicDeviceItemModel] = []
    var storageDevices: [VMModelFieldStorageDeviceItemModel] = []
    var networkDevices: [VMModelFieldNetworkDeviceItemModel] = []
    
    var pointingDevices: [VMModelFieldPointingDeviceItemModel] = []
    var audioDevices: [VMModelFieldAudioDeviceItemModel] = []
    
    var directorySharingDevices: [VMModelFieldDirectorySharingDeviceItemModel] = []
    var linuxFeatures: VMLinuxFeatureConfiguration = .legacy
    
    convenience init() {
        // default
        self.init(configModel: VMConfigModel.createWithDefaultValues(osType: .macOS))
    }

    init(configModel: VMConfigModel) {
        self.setValuesWithConfigModel(configModel: configModel)
    }
    
    func setValuesWithConfigModel(configModel: VMConfigModel) {
        self.osType = configModel.type
        self.name = configModel.name
        self.remark = configModel.remark
        
        self.cpuCount = configModel.cpu.count
        self.memorySize = configModel.memory.size
        
        self.storageDevices.removeAll()
        for item in configModel.storageDevices {
            self.storageDevices.append(VMModelFieldStorageDeviceItemModel(data: item))
        }
        self.graphicDevices.removeAll()
        for item in configModel.graphicsDevices {
            self.graphicDevices.append(VMModelFieldGraphicDeviceItemModel(data: item))
        }
        self.networkDevices.removeAll()
        for item in configModel.networkDevices {
            self.networkDevices.append(VMModelFieldNetworkDeviceItemModel(data: item))
        }
        self.pointingDevices.removeAll()
        for item in configModel.pointingDevices {
            self.pointingDevices.append(VMModelFieldPointingDeviceItemModel(data: item))
        }
        self.audioDevices.removeAll()
        for item in configModel.audioDevices {
            self.audioDevices.append(VMModelFieldAudioDeviceItemModel(data: item))
        }
        self.directorySharingDevices = configModel.directorySharingDevices.map(VMModelFieldDirectorySharingDeviceItemModel.init(data:))
        self.linuxFeatures = configModel.linuxFeatures ?? .legacy
    }
    
    func resetDefaultConfig() {
        let defaultConfig = VMConfigModel.createWithDefaultValues(osType: osType)
        setValuesWithConfigModel(configModel: defaultConfig)
    }
    
    func getConfigModel() -> VMConfigModel {
        
        let cpu = VMModelFieldCPU(count: self.cpuCount)
        let memory = VMModelFieldMemory(size: self.memorySize)
        let graphicDevices = self.graphicDevices.map({$0.data})
        let storageDevices = self.storageDevices.map({$0.data})
        let networkDevices = self.networkDevices.map({$0.data})
        let pointingDevices = self.pointingDevices.map({$0.data})
        let audioDevices = self.audioDevices.map({$0.data})
        let directorySharingDevices = self.directorySharingDevices.map({$0.data})
        
        return VMConfigModel(type: osType, name: name, remark: remark, cpu: cpu, memory: memory, graphicsDevices: graphicDevices, storageDevices: storageDevices, networkDevices: networkDevices, pointingDevices: pointingDevices, audioDevices: audioDevices, directorySharingDevices: directorySharingDevices, linuxFeatures: osType == .linux ? linuxFeatures : nil)
    }
    
}
#endif
