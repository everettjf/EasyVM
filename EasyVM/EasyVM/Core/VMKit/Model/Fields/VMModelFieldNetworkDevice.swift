//
//  VMModelFieldNetworkDevice.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation
import Virtualization

struct VMModelFieldNetworkDevice : Decodable, CustomStringConvertible {
    
    enum DeviceType : String, CaseIterable, Identifiable, Decodable {
        case NAT, Bridged, FileHandle
        var id: Self { self }
    }
    
    let type: DeviceType
    
    var description: String {
        return "\(type)"
    }
    
    
    static func `default`() -> VMModelFieldNetworkDevice {
        return VMModelFieldNetworkDevice(type: .NAT)
    }
    
    static func createConfiguration(model: VMModelFieldNetworkDevice) -> VZNetworkDeviceConfiguration {
        if model.type == .NAT {
            let networkDevice = VZVirtioNetworkDeviceConfiguration()
            let networkAttachment = VZNATNetworkDeviceAttachment()
            networkDevice.attachment = networkAttachment
            return networkDevice
        } else if model.type == .Bridged {
            // TODO: bridge
        } else if model.type == .FileHandle {
            // TODO: filehandle
        }
        
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        let networkAttachment = VZNATNetworkDeviceAttachment()
        networkDevice.attachment = networkAttachment
        return networkDevice
    }
}
