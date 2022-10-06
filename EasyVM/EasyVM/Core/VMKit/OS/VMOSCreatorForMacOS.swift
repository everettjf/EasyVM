//
//  VMOSCreatorForMacOS.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/1.
//

import Foundation
import Virtualization


class VMOSCreatorForMacOS : VMOSCreator {
    
    
    private var installationObserver: NSKeyValueObservation?
    private var virtualMachine: VZVirtualMachine!
    
    deinit {
        print("de init")
    }
    
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

            // load image
            progress(.info("Begin load system image : \(model.state.imagePath.path(percentEncoded: false))"))
            let restoreImage = try await loadSystemImage(ipswURL: model.state.imagePath)
            progress(.info("Succeed load system image"))
            
            progress(.info("Begin check image"))
            let macOSConfigurationRequirements = try await checkSystemImage(restoreImage: restoreImage)
            progress(.info("Succeed check image"))
            
            // setup
            progress(.info("Begin setup virtual machine"))
            try await setupVirtualMachine(model: model, macOSConfigurationRequirements: macOSConfigurationRequirements, progress: progress)
            progress(.info("Succeed setup virtual machine"))
            
            // install
            progress(.info("Begin install"))
            try await startInstallation(restoreImageURL: model.state.imagePath, progress: progress)
            progress(.info("Succeed install"))
            
        } catch {
            progress(.error("\(error)"))
            return .failure("\(error)")
        }
        
        progress(.info("Succeed created virtual machine"))
        
        return .success
    }
    
    
    private func startInstallation(restoreImageURL: URL, progress: @escaping (VMOSCreatorProgressInfo) -> Void) async throws {
        return try await withCheckedThrowingContinuation({ continuation in
            DispatchQueue.main.async {

                let installer = VZMacOSInstaller(virtualMachine: self.virtualMachine, restoringFromImageAt: restoreImageURL)
                
                progress(.info("Begin real install, please wait..."))
                installer.install(completionHandler: { (result: Result<Void,Error>) in
                    if case let .failure(error) = result {
                        continuation.resume(throwing: error)
                        return
                    }
                    
                    progress(.info("Succeed install"))
                    continuation.resume(returning: ())
                })

                // Observe installation progress
                self.installationObserver = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { (current, change) in
                    guard let newValue = change.newValue else {
                        return
                    }
                    progress(.progress(newValue))
                }
            }
        })
    }
    
    
    private func setupVirtualMachine(model: VMModel, macOSConfigurationRequirements: VZMacOSConfigurationRequirements, progress: @escaping (VMOSCreatorProgressInfo) -> Void) async throws {
        return try await withCheckedThrowingContinuation({ continuation in
            let virtualMachineConfiguration = VZVirtualMachineConfiguration()

            // platform
            do {
                let macPlatformConfiguration = VZMacPlatformConfiguration()
                let auxiliaryStorage = try VZMacAuxiliaryStorage(creatingStorageAt: model.auxiliaryStorageURL, hardwareModel: macOSConfigurationRequirements.hardwareModel, options: [])
                
                macPlatformConfiguration.auxiliaryStorage = auxiliaryStorage
                macPlatformConfiguration.hardwareModel = macOSConfigurationRequirements.hardwareModel
                macPlatformConfiguration.machineIdentifier = VZMacMachineIdentifier()
    
                // Store the hardware model and machine identifier to disk so that we
                // can retrieve them for subsequent boots.
                try macPlatformConfiguration.hardwareModel.dataRepresentation.write(to: model.hardwareModelURL)
                try macPlatformConfiguration.machineIdentifier.dataRepresentation.write(to: model.machineIdentifierURL)
                
                virtualMachineConfiguration.platform = macPlatformConfiguration
            } catch {
                continuation.resume(throwing: error)
                return
            }
            progress(.info("- Platform OK"))
            
            // cpu
            virtualMachineConfiguration.cpuCount = model.config.cpu.count
            if virtualMachineConfiguration.cpuCount < macOSConfigurationRequirements.minimumSupportedCPUCount {
                continuation.resume(throwing: VMOSError.regularFailure("CPUCount isn't supported by the macOS configuration."))
                return
            }
            progress(.info("- CPU OK"))
            
            // memory
            virtualMachineConfiguration.memorySize = model.config.memory.size
            if virtualMachineConfiguration.memorySize < macOSConfigurationRequirements.minimumSupportedMemorySize {
                continuation.resume(throwing: VMOSError.regularFailure("memorySize isn't supported by the macOS configuration. required \(virtualMachineConfiguration.memorySize) , minimum \(macOSConfigurationRequirements.minimumSupportedMemorySize)"))
                return
            }
            progress(.info("- Memory OK"))
            
            // bootLoader
            virtualMachineConfiguration.bootLoader = VZMacOSBootLoader()
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
            
            // keyboards
            virtualMachineConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
            
            // directorySharingDevices
            virtualMachineConfiguration.directorySharingDevices = model.config.directorySharingDevices.compactMap({$0.createConfiguration()})
            
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
    
    
    private func checkSystemImage(restoreImage: VZMacOSRestoreImage) async throws -> VZMacOSConfigurationRequirements {
        return try await withCheckedThrowingContinuation({ continuation in
            guard let macOSConfiguration = restoreImage.mostFeaturefulSupportedConfiguration else {
                continuation.resume(throwing: VMOSError.regularFailure("No supported configuration available."))
                return
            }

            if !macOSConfiguration.hardwareModel.isSupported {
                continuation.resume(throwing: VMOSError.regularFailure("macOSConfiguration configuration isn't supported on the current host."))
                return
            }

            continuation.resume(returning: macOSConfiguration)
        })
    }
    
    private func loadSystemImage(ipswURL: URL) async throws -> VZMacOSRestoreImage {
        return try await withCheckedThrowingContinuation({ continuation in
            VZMacOSRestoreImage.load(from: ipswURL) { result in
                switch result {
                case let .failure(error):
                    continuation.resume(throwing: error)
                case let .success(systemImage):
                    continuation.resume(returning: systemImage)
                }
            }
        })
    }
    
    
}
