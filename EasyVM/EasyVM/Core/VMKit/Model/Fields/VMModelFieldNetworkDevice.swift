//
//  VMModelFieldNetworkDevice.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation
import Virtualization

#if arch(arm64)
struct VMModelFieldNetworkDevice : Decodable, Encodable, CustomStringConvertible {
    
    enum DeviceType : String, CaseIterable, Identifiable, Decodable, Encodable {
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
    
    func createConfiguration() -> VZNetworkDeviceConfiguration {
        if self.type == .NAT {
            let networkDevice = VZVirtioNetworkDeviceConfiguration()
            let networkAttachment = VZNATNetworkDeviceAttachment()
            networkDevice.attachment = networkAttachment
            return networkDevice
        } else if self.type == .Bridged {
            // TODO: bridge
        } else if self.type == .FileHandle {
            // TODO: filehandle
        }
        
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        let networkAttachment = VZNATNetworkDeviceAttachment()
        networkDevice.attachment = networkAttachment
        return networkDevice
    }
}

#endif
