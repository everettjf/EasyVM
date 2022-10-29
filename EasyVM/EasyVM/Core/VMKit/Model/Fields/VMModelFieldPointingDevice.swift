//
//  VMModelFieldPointingDevice.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation
import Virtualization

#if arch(arm64)

struct VMModelFieldPointingDevice: Decodable, Encodable, CustomStringConvertible {
    
    enum DeviceType : String, CaseIterable, Identifiable, Decodable, Encodable {
        case USBScreenCoordinatePointing, MacTrackpad
        var id: Self { self }
    }
    
    let type: DeviceType
    
    var description: String {
        return "\(type)"
    }
    
    static func `default`() -> VMModelFieldPointingDevice {
        return VMModelFieldPointingDevice(type: .USBScreenCoordinatePointing)
    }
    
    func createConfiguration() -> VZPointingDeviceConfiguration {
        if self.type == .USBScreenCoordinatePointing {
            return VZUSBScreenCoordinatePointingDeviceConfiguration()
        }
        return VZMacTrackpadConfiguration()
    }
}

#endif
