//
//  VMModel.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/6.
//

import Foundation
import SwiftUI



struct VMConfigModel : Decodable {
    let type: VMOSType
    let name: String
    let remark: String?
    let cpu: VMModelFieldCPU
    let memory: VMModelFieldMemory
    let graphicsDevices: [VMModelFieldGraphicDevice]
    let storageDevices: [VMModelFieldStorageDevice]
    let networkDevices: [VMModelFieldNetworkDevice]
    let pointingDevices: [VMModelFieldPointingDevice]
    let keyboardDevices: [VMModelFieldKeyboardDevice]
    let audioDevices: [VMModelFieldAudioDevice]
    
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
