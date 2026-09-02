//
//  VMModelFieldPointingDevice.swift
//  EZVM
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

        var displayName: String {
            switch self {
            case .USBScreenCoordinatePointing: "Absolute Pointer"
            case .MacTrackpad: "Mac Trackpad"
            }
        }

        var detail: String {
            switch self {
            case .USBScreenCoordinatePointing: "Best compatibility for Linux installers and desktops"
            case .MacTrackpad: "Native gestures for macOS guests"
            }
        }
    }
    
    let type: DeviceType
    
    var description: String {
        return type.displayName
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
