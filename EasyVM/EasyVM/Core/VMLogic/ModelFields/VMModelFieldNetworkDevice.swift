//
//  VMModelFieldNetworkDevice.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation
import Virtualization

struct VMModelFieldNetworkDevice : Decodable {
    let type: String
    
    
    static func `default`() -> VMModelFieldNetworkDevice {
        return VMModelFieldNetworkDevice(type: "nat")
    }
    
    static func createConfiguration(model: VMModelFieldNetworkDevice) -> VZNetworkDeviceConfiguration {
        if model.type == "nat" {
            let networkDevice = VZVirtioNetworkDeviceConfiguration()
            let networkAttachment = VZNATNetworkDeviceAttachment()
            networkDevice.attachment = networkAttachment
            return networkDevice
        } else if model.type == "bridged" {
            // TODO: bridge
        } else if model.type == "filehandle" {
            // TODO: filehandle
        }
        
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        let networkAttachment = VZNATNetworkDeviceAttachment()
        networkDevice.attachment = networkAttachment
        return networkDevice
    }
}
