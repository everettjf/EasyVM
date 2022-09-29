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

class VMConfigurationViewState: ObservableObject {
    @Published var cpuCount: Int = 1
    @Published var memorySize: UInt64 = 1024 * 1024 * 1024 * 2
    @Published var diskSize: UInt64 = 1024 * 1024 * 1024 * 64
    
    @Published var graphicDevices: [VMModelFieldGraphicDeviceItemModel] = []
    
    init() {
        self.cpuCount = VMModelFieldCPU.defaultCount()
        self.graphicDevices = [
            VMModelFieldGraphicDeviceItemModel(data: VMModelFieldGraphicDevice.default())
        ]

    }
}
