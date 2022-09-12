//
//  VMModelFieldGraphicDevice.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation
import Virtualization

struct VMModelFieldGraphicDevice : Decodable {
    let type: String
    let width: Int
    let height: Int
    let pixelsPerInch: Int
    
    static func `default`() -> VMModelFieldGraphicDevice {
        return VMModelFieldGraphicDevice(type: "mac", width: 1920, height: 1200, pixelsPerInch: 80)
    }
    
    static func createConfiguration(model: VMModelFieldGraphicDevice) -> VZGraphicsDeviceConfiguration {
        
        if model.type == "mac" {
            let graphicsConfiguration = VZMacGraphicsDeviceConfiguration()
            graphicsConfiguration.displays = [
                // We abitrarily choose the resolution of the display to be 1920 x 1200.
                VZMacGraphicsDisplayConfiguration(widthInPixels: model.width, heightInPixels: model.height, pixelsPerInch: model.pixelsPerInch)
            ]
            return graphicsConfiguration
        } else if model.type == "virtio" {
            let config = VZVirtioGraphicsDeviceConfiguration()
            config.scanouts = [
                VZVirtioGraphicsScanoutConfiguration(widthInPixels: model.width, heightInPixels: model.height)
            ]
            return config
        } else {
            let graphicsConfiguration = VZMacGraphicsDeviceConfiguration()
            graphicsConfiguration.displays = [
                // We abitrarily choose the resolution of the display to be 1920 x 1200.
                VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80)
            ]
            return graphicsConfiguration
        }
    }
}
