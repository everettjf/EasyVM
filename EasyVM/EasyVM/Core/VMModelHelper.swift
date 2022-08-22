//
//  VMModelHelper.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/22.
//

import Foundation
import Virtualization

#if arch(arm64)


struct VMModelHelper_CPU {
    
    static func defaultCount() -> Int {
        let totalAvailableCPUs = ProcessInfo.processInfo.processorCount
        var virtualCPUCount = totalAvailableCPUs <= 1 ? 1 : totalAvailableCPUs - 1
        virtualCPUCount = Swift.max(virtualCPUCount, Self.minCount())
        virtualCPUCount = Swift.min(virtualCPUCount, Self.maxCount())
        return virtualCPUCount
    }
    
    static func maxCount() -> Int {
        return VZVirtualMachineConfiguration.maximumAllowedCPUCount
    }
    
    static func minCount() -> Int {
        return VZVirtualMachineConfiguration.minimumAllowedCPUCount
    }
    
}


struct VMModelHelper_Memory {
    static func defaultSize() -> UInt64 {
        // We arbitrarily choose 4GB.
        var memorySize = (4 * 1024 * 1024 * 1024) as UInt64
        memorySize = Swift.max(memorySize, Self.minSize())
        memorySize = Swift.min(memorySize, Self.maxSize())

        return memorySize
    }
    
    static func maxSize() -> UInt64 {
        return VZVirtualMachineConfiguration.maximumAllowedMemorySize
    }
    
    static func minSize() -> UInt64 {
        return VZVirtualMachineConfiguration.minimumAllowedMemorySize
    }
    
}

struct VMModelHelper_GraphicsDevice {
    
    
    static func defaultModel() -> VMGraphicDeviceModel {
        return VMGraphicDeviceModel(type: "mac", width: 1920, height: 1200, pixelsPerInch: 80)
    }
    
    static func createConfiguration(model: VMGraphicDeviceModel) -> VZGraphicsDeviceConfiguration {
        
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

struct VMModelHelper_Storage {
    
    static func defaultDiskSize() -> UInt64 {
        // 64GB
        return 64 * 1024 * 1024 * 1024
    }
    
    static func minDiskSize() -> UInt64 {
        return 10 * 1024 * 1024 * 1024
    }
    
    static func maxDiskSize() -> UInt64 {
        // TODO: get host disk left size
        return 10 * 1024 * 1024 * 1024 * 1024
    }
    
    static func defaultModel(location: VMLocationModel) -> VMStorageDeviceModel {
        return VMStorageDeviceModel(type: "disk", size: Self.defaultDiskSize(), imagePath: location.getMainDiskImage())
    }
}


struct VMModelHelper_Network {
    static func defaultModel() -> VMNetworkDeviceModel {
        return VMNetworkDeviceModel(type: "nat")
    }
    
    static func createConfiguration(model: VMNetworkDeviceModel) -> VZNetworkDeviceConfiguration {
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


struct VMModelHelper_PointingDevice {
    static func defaultModel() -> VMPointingDeviceModel {
        return VMPointingDeviceModel(type: "usbscreen")
    }
    
    static func createConfiguration(model: VMPointingDeviceModel) -> VZPointingDeviceConfiguration {
        return VZUSBScreenCoordinatePointingDeviceConfiguration()
    }
}




#endif
