//
//  VMOSRunnerForLinux.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/5.
//

import Foundation
import Virtualization

class VMOSRunnerForLinux : VMOSRunner {
    
    
    func createConfiguration(model: VMModel) -> VMOSResult<VZVirtualMachineConfiguration, String> {
        
        let virtualMachineConfiguration = VZVirtualMachineConfiguration()

        // platform
        let platformResult = createLinuxPlatformConfiguration(model: model)
        switch platformResult {
        case .failure(let error):
            return .failure(error)
        case .success(let platform):
            virtualMachineConfiguration.platform = platform
        }
        
        // cpu
        virtualMachineConfiguration.cpuCount = model.config.cpu.count
        
        // memory
        virtualMachineConfiguration.memorySize = model.config.memory.size
        
        // bootLoader
        let bootLoaderResult = createBootLoader(model: model)
        switch bootLoaderResult {
        case .failure(let error):
            return .failure(error)
        case .success(let bootLoader):
            virtualMachineConfiguration.bootLoader = bootLoader
        }
        
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
        
        // consoleDevices
        virtualMachineConfiguration.consoleDevices = [createSpiceAgentConsoleDeviceConfiguration()]
        
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
    
    
    private func createLinuxPlatformConfiguration(model: VMModel) -> VMOSResult<VZGenericPlatformConfiguration, String> {
        
        let linuxPlatform = VZGenericPlatformConfiguration()
        
        // Retrieve the machine identifier.
        guard let machineIdentifierData = try? Data(contentsOf: model.machineIdentifierURL) else {
            return .failure("Failed to retrieve the machine identifier data.")
        }

        guard let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: machineIdentifierData) else {
            return .failure("Failed to create the machine identifier.")
        }

        linuxPlatform.machineIdentifier = machineIdentifier
        
        return .success(linuxPlatform)
    }

    
    
    private func createBootLoader(model: VMModel) -> VMOSResult<VZEFIBootLoader, String> {
        if !FileManager.default.fileExists(atPath: model.efiVariableStoreURL.path(percentEncoded: false)) {
            return .failure("EFI variable store does not exist.")
        }

        let variableStore = VZEFIVariableStore(url: model.efiVariableStoreURL)
        let bootloader = VZEFIBootLoader()
        bootloader.variableStore = variableStore
        
        return .success(bootloader)
    }
    
    
    private func createSpiceAgentConsoleDeviceConfiguration() -> VZVirtioConsoleDeviceConfiguration {
        let consoleDevice = VZVirtioConsoleDeviceConfiguration()

        let spiceAgentPort = VZVirtioConsolePortConfiguration()
        spiceAgentPort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        spiceAgentPort.attachment = VZSpiceAgentPortAttachment()
        consoleDevice.ports[0] = spiceAgentPort

        return consoleDevice
    }
}
