//
//  VMModel.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/6.
//

import Foundation
import SwiftUI



struct VMBasicModel: Decodable {
    let name: String
    let remark: String
}

struct VMConfigModel : Decodable {
    let type: VMOSType
    let cpu: VMModelFieldCPU
    let memory: VMModelFieldMemory
    let graphicsDevices: [VMModelFieldGraphicDevice]
    let storageDevices: [VMModelFieldStorageDevice]
    let networkDevices: [VMModelFieldNetworkDevice]
    let pointingDevices: [VMModelFieldPointingDevice]
    let audioDevices: [VMModelFieldAudioDevice]
    
    static func create(osType: VMOSType) -> VMConfigModel {
        return VMConfigModel(type: osType, cpu: VMModelFieldCPU.default(), memory: VMModelFieldMemory.default(), graphicsDevices: [VMModelFieldGraphicDevice.default()], storageDevices: [VMModelFieldStorageDevice.default()], networkDevices: [VMModelFieldNetworkDevice.default()], pointingDevices: [VMModelFieldPointingDevice(type: .USBScreenCoordinatePointing)], audioDevices: VMModelFieldAudioDevice.defaults())
    }
}


struct VMModel: Identifiable {
    let id = UUID()
    let rootPath: URL
    let imagePath: URL
    let basic: VMBasicModel
    let config: VMConfigModel
    
    
    func getRootPath() -> URL {
        return rootPath
    }
    
}
