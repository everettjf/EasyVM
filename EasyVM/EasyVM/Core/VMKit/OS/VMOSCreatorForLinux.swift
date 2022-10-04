//
//  VMOSCreatorForLinux.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/4.
//

import Foundation
import Virtualization


class VMOSCreatorForLinux: VMOSCreator {
    
    
    private var virtualMachine: VZVirtualMachine!

    
    func create(model: VMModel, progress: @escaping (VMOSCreatorProgressInfo) -> Void) async -> VMOSResultVoid {
        
        do {
            // create bundle
            let rootPath = model.getRootPath()
            progress(.info("Begin create bundle path : \(rootPath.path(percentEncoded: false))"))
            try await VMOSCreatorUtil.createVMBundle(path: rootPath)
            progress(.info("Succeed create bundle path"))
            
            // write json
            progress(.info("Begin write config : \(model.configURL.path(percentEncoded: false))"))
            try await model.config.writeConfigToFile(path: model.configURL)
            try await model.state.writeStateToFile(path: model.stateURL)
            progress(.info("Succeed write config"))

            // setup
            progress(.info("Begin setup virtual machine"))
            try await setupVirtualMachine(model: model, progress: progress)
            progress(.info("Succeed setup virtual machine"))
            
        } catch {
            progress(.error("\(error)"))
            return .failure("\(error)")
        }
        
        progress(.info("Succeed created virtual machine"))
        return .success
    }
    
    
    private func setupVirtualMachine(model: VMModel, progress: @escaping (VMOSCreatorProgressInfo) -> Void) async throws {
        return try await withCheckedThrowingContinuation({ continuation in
            let virtualMachineConfiguration = VZVirtualMachineConfiguration()

            // platform
            do {
                let platform = VZGenericPlatformConfiguration()
                
                // create
                // Store the machine identifier to disk so you can retrieve it for subsequent boots.
                let machineIdentifier = VZGenericMachineIdentifier()
                try machineIdentifier.dataRepresentation.write(to: model.machineIdentifierURL)
                platform.machineIdentifier = machineIdentifier

                virtualMachineConfiguration.platform = platform
            } catch {
                continuation.resume(throwing: error)
                return
            }
            progress(.info("- Platform OK"))
            
            // cpu
            virtualMachineConfiguration.cpuCount = model.config.cpu.count
            progress(.info("- CPU OK"))
            
            // memory
            virtualMachineConfiguration.memorySize = model.config.memory.size
            progress(.info("- Memory OK"))
            
            // bootLoader
            do {
                let bootloader = VZEFIBootLoader()
                let efiVariableStore = try VZEFIVariableStore(creatingVariableStoreAt: model.efiVariableStoreURL)
                bootloader.variableStore = efiVariableStore
                virtualMachineConfiguration.bootLoader = bootloader
            } catch {
                continuation.resume(throwing: error)
                return
            }
            progress(.info("- BootLoader OK"))
            
            // graphicsDevices
            virtualMachineConfiguration.graphicsDevices = model.config.graphicsDevices.map({$0.createConfiguration()})
            progress(.info("- Graphics Devices OK"))
            
            // storageDevices
            virtualMachineConfiguration.storageDevices = []
            for item in model.config.storageDevices {
                let result = item.createConfiguration(rootPath: model.rootPath)
                switch result {
                case .failure(let error):
                    continuation.resume(throwing: VMOSError.regularFailure(error))
                    return
                case .success(let configItem):
                    virtualMachineConfiguration.storageDevices.append(configItem)
                }
            }
            progress(.info("- Storage Devices OK"))
            
            // networkDevices
            virtualMachineConfiguration.networkDevices = model.config.networkDevices.map({$0.createConfiguration()})
            progress(.info("- Network Devices OK"))
            
            // pointingDevices
            virtualMachineConfiguration.pointingDevices = model.config.pointingDevices.map({$0.createConfiguration()})
            progress(.info("- Pointing Devices OK"))
            
            // audioDevices
            virtualMachineConfiguration.audioDevices = model.config.audioDevices.map({$0.createConfiguration()})
            progress(.info("- Audio Devices OK"))
            
            // Validate
            progress(.info("Begin validate"))
            do {
                try virtualMachineConfiguration.validate()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            progress(.info("Succeed validate"))
            
            // Create
            progress(.info("Begin create virtual machine instance"))
            virtualMachine = VZVirtualMachine(configuration: virtualMachineConfiguration)
            progress(.info("Succeed create virtual machine instance"))

            continuation.resume(returning: ())
        })
    }
    
}
