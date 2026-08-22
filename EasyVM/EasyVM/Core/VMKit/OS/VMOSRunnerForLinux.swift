//
//  VMOSRunnerForLinux.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/5.
//

import Foundation
import Virtualization

#if arch(arm64)
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
        switch VMModelFieldNetworkDevice.createConfigurations(model.config.networkDevices) {
        case .success(let devices): virtualMachineConfiguration.networkDevices = devices
        case .failure(let error): return .failure(error)
        }
        
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

        let features = model.config.linuxFeatures ?? .legacy
        switch features.applyDevices(
            to: virtualMachineConfiguration,
            existingDirectoryTags: Set(model.config.directorySharingDevices.map(\.tag))
        ) {
        case .success: break
        case .failure(let error): return .failure(error)
        }
        
        
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

        if case let .failure(error) = (model.config.linuxFeatures ?? .legacy).applyPlatform(to: linuxPlatform) {
            return .failure(error)
        }
        
        return .success(linuxPlatform)
    }

    
    
    private func createBootLoader(model: VMModel) -> VMOSResult<VZEFIBootLoader, String> {
        if !FileManager.default.fileExists(atPath: model.efiVariableStoreURL.path(percentEncoded: false)),
           VMReleaseSmokeTest.configuration(for: model.rootPath) != nil {
            do {
                _ = try VZEFIVariableStore(creatingVariableStoreAt: model.efiVariableStoreURL)
            } catch {
                return .failure("Could not create the release smoke EFI variable store: \(error.localizedDescription)")
            }
        }
        if !FileManager.default.fileExists(atPath: model.efiVariableStoreURL.path(percentEncoded: false)) {
            return .failure("EFI variable store does not exist.")
        }

        let variableStore = VZEFIVariableStore(url: model.efiVariableStoreURL)
        if let features = model.config.linuxFeatures {
            if features.secureBootEnabled,
               !(VirtualizationCapability.efiSecureBoot.isAvailable
                 && UserDefaults.standard.bool(forKey: EasyVMExperimentalFeatures.efiSecureBootKey)) {
                return .failure("UEFI Secure Boot requires macOS 27 and the EFI Secure Boot experimental feature in Settings.")
            }
            if #available(macOS 27.0, *),
               UserDefaults.standard.bool(forKey: EasyVMExperimentalFeatures.efiSecureBootKey),
               case let .failure(error) = VMEFISecureBootManager.apply(enabled: features.secureBootEnabled, variableStore: variableStore) {
                return .failure(error)
            }
        }
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

#endif
