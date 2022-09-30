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



class VMConfigurationViewState: ObservableObject {
    @Published var cpuCount: Int = 1
    @Published var memorySize: UInt64 = 1024 * 1024 * 1024 * 2
    @Published var diskSize: UInt64 = 1024 * 1024 * 1024 * 64

    @Published var graphicDevices: [VMModelFieldGraphicDeviceItemModel] = []
    @Published var storageDevices: [VMModelFieldStorageDeviceItemModel] = []
    @Published var networkDevices: [VMModelFieldNetworkDeviceItemModel] = []
    
    init(location: VMLocationModel) {
        self.storageDevices = [
            VMModelFieldStorageDeviceItemModel(data: VMModelFieldStorageDevice.default(location: location))
        ]
        self.cpuCount = VMModelFieldCPU.defaultCount()
        self.graphicDevices = [
            VMModelFieldGraphicDeviceItemModel(data: VMModelFieldGraphicDevice.default())
        ]
        self.networkDevices = [
            VMModelFieldNetworkDeviceItemModel(data: VMModelFieldNetworkDevice.default())
        ]
    }
    
    init() {
        self.storageDevices = []
        self.cpuCount = VMModelFieldCPU.defaultCount()
        self.graphicDevices = [
            VMModelFieldGraphicDeviceItemModel(data: VMModelFieldGraphicDevice.default())
        ]
        self.networkDevices = [
            VMModelFieldNetworkDeviceItemModel(data: VMModelFieldNetworkDevice.default())
        ]
    }
}
