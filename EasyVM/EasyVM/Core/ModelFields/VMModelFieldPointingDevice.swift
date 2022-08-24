//
//  VMModelFieldPointingDevice.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation
import Virtualization


struct VMModelFieldPointingDevice: Decodable {
    let type: String
    
    
    static func `default`() -> VMModelFieldPointingDevice {
        return VMModelFieldPointingDevice(type: "usbscreen")
    }
    
    static func createConfiguration(model: VMModelFieldPointingDevice) -> VZPointingDeviceConfiguration {
        return VZUSBScreenCoordinatePointingDeviceConfiguration()
    }
}
