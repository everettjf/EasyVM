//
//  VMModelFieldPointingDevice.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation
import Virtualization


struct VMModelFieldPointingDevice: Decodable, CustomStringConvertible {
    
    enum DeviceType : String, CaseIterable, Identifiable, Decodable {
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
    
    static func createConfiguration(model: VMModelFieldPointingDevice) -> VZPointingDeviceConfiguration {
        if model.type == .USBScreenCoordinatePointing {
            return VZUSBScreenCoordinatePointingDeviceConfiguration()
        }
        return VZMacTrackpadConfiguration()
    }
}
