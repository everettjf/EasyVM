//
//  VMModel.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/6.
//

import Foundation
import SwiftUI


enum VMModelOSType: String, Identifiable, CaseIterable, Hashable, Decodable {
    case macOS = "macOS"
    case linux = "linux"
    
    var name: String { rawValue }
    var id: String { rawValue }
}


struct VMGraphicDeviceModel : Decodable {
    let type: String
    let width: Int
    let height: Int
    let pixelsPerInch: Int
}

struct VMStorageDeviceModel : Decodable {
    let type: String
    let size: UInt64?
    let imagePath: String?
}

struct VMNetworkDeviceModel : Decodable {
    let type: String
}

struct VMPointingDeviceModel: Decodable {
    let type: String
}

struct VMKeyboardDeviceModel: Decodable {
    let type: String
    
    init(type: String) {
        self.type = type
    }
    
    static func defaultModel() -> VMKeyboardDeviceModel {
        return VMKeyboardDeviceModel(type: "usb")
    }
    
    
}

struct VMAudioDeviceModel: Decodable {
    let type: String
    
    init(type: String) {
        self.type = type
    }
    
    static func defaultModels() -> [VMAudioDeviceModel] {
        return [
            VMAudioDeviceModel(type: "input"),
            VMAudioDeviceModel(type: "output"),
        ]
    }
}

struct VMConfigModel : Decodable {
    let type: VMModelOSType
    let name: String
    let remark: String?
    let cpuCount: Int
    let memorySize: UInt64
    let graphicsDevices: [VMGraphicDeviceModel]
    let storageDevices: [VMStorageDeviceModel]
    let networkDevices: [VMNetworkDeviceModel]
    let pointingDevices: [VMPointingDeviceModel]
    let keyboardDevices: [VMKeyboardDeviceModel]
    let audioDevices: [VMAudioDeviceModel]
    
}

struct VMLocationModel : Decodable {
    let root: String
    let image: String
    
    func getMainDiskImage() -> String {
        return root + "Disk.img"
    }
}


struct VMModel: Identifiable {
    let id = UUID()
    let location: VMLocationModel
    let config: VMConfigModel
}


let allVirtualMachines: [VMModel] = [
]
