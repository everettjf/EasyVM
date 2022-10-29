//
//  VMOSRunnerForMacOS.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/5.
//

import Foundation
import Virtualization

#if arch(arm64)

class VMOSRunnerForMacOS : VMOSRunner {
    
    
    func createConfiguration(model: VMModel) -> VMOSResult<VZVirtualMachineConfiguration, String> {
        
        let virtualMachineConfiguration = VZVirtualMachineConfiguration()

        // platform
        let platformResult = createMacPlatformConfiguration(model: model)
        switch platformResult {
        case .failure(let error):
            return .failure(error)
        case .success(let macPlatform):
            virtualMachineConfiguration.platform = macPlatform
        }
        
        // cpu
        virtualMachineConfiguration.cpuCount = model.config.cpu.count
        
        // memory
        virtualMachineConfiguration.memorySize = model.config.memory.size
        
        // bootLoader
        virtualMachineConfiguration.bootLoader = VZMacOSBootLoader()
        
        // graphicsDevices
        virtualMachineConfiguration.graphicsDevices = model.config.graphicsDevices.map({$0.createConfiguration()})
        
        // storageDevices
        virtualMachineConfiguration.storageDevices = []
        for item in model.config.storageDevices {
            let result = item.createConfiguration(rootPath: model.rootPath)
            switch result {
            case .failure(let error):
                return .failure(error)
            case .success(let configItem):
                virtualMachineConfiguration.storageDevices.append(configItem)
            }
        }
        
        // networkDevices
        virtualMachineConfiguration.networkDevices = model.config.networkDevices.map({$0.createConfiguration()})
        
        // pointingDevices
        virtualMachineConfiguration.pointingDevices = model.config.pointingDevices.map({$0.createConfiguration()})
        
        // audioDevices
        virtualMachineConfiguration.audioDevices = model.config.audioDevices.map({$0.createConfiguration()})
        
        // keyboards
        virtualMachineConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
        
        
        // directorySharingDevices
        virtualMachineConfiguration.directorySharingDevices = model.config.directorySharingDevices.compactMap({$0.createConfiguration()})
        
        
        // Validate
        do {
            try virtualMachineConfiguration.validate()
        } catch {
            return .failure("failed to validate : \(error)")
        }
        
        return .success(virtualMachineConfiguration)
        
    }
    
    
    private func createMacPlatformConfiguration(model: VMModel) -> VMOSResult<VZMacPlatformConfiguration, String> {
        
        let macPlatform = VZMacPlatformConfiguration()
        
        let auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: model.auxiliaryStorageURL)
        macPlatform.auxiliaryStorage = auxiliaryStorage
        
        // Retrieve the hardware model; you should save this value to disk
        // during installation.
        guard let hardwareModelData = try? Data(contentsOf: model.hardwareModelURL) else {
            return .failure("Failed to retrieve hardware model data.")
        }
        
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
            return .failure("Failed to create hardware model.")
        }
        
        if !hardwareModel.isSupported {
            return .failure("The hardware model isn't supported on the current host")
        }
        macPlatform.hardwareModel = hardwareModel
        
        // Retrieve the machine identifier; you should save this value to disk
        // during installation.
        guard let machineIdentifierData = try? Data(contentsOf: model.machineIdentifierURL) else {
            return .failure("Failed to retrieve machine identifier data.")
        }
        
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineIdentifierData) else {
            return .failure("Failed to create machine identifier.")
        }
        macPlatform.machineIdentifier = machineIdentifier
        
        return .success(macPlatform)
    }

}

#endif
