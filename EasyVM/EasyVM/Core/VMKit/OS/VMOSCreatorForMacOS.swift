//
//  VMOSCreatorForMacOS.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/1.
//

import Foundation
import Virtualization



class VMOSCreatorForMacOSDelegate: NSObject, VZVirtualMachineDelegate {
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        NSLog("!! Virtual machine did stop with error: \(error.localizedDescription)")
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        NSLog("!! Guest did stop virtual machine.")
    }
}


class VMOSCreatorForMacOS : VMOSCreator {
    
    
    private var installationObserver: NSKeyValueObservation?
    private var virtualMachine: VZVirtualMachine!
    private var virtualMachineResponder: VMOSCreatorForMacOSDelegate?
    
    deinit {
        print("de init")
    }
    
    func create(vmModel: VMModel) async -> VMOSResultVoid {
        
        do {
            // create bundle
            let rootPath = vmModel.getRootPath()
            try await createVMBundle(path: rootPath)
            print("Create root bundle succeed")
            
            // write json
            try await vmModel.writeConfigToFile(path: vmModel.configURL)

            // load image
            let restoreImage = try await loadSystemImage(ipswURL: vmModel.imagePath)
            let macOSConfiguration = try await checkSystemImage(restoreImage: restoreImage)
            
            // setup
            try await setupVirtualMachine(vmModel: vmModel, macOSConfiguration: macOSConfiguration)
            
            // install
            try await startInstallation(restoreImageURL: vmModel.imagePath)
            
        } catch {
            return .failure("\(error)")
        }
        
        return .success
    }
    
    
    private func startInstallation(restoreImageURL: URL) async throws {
        return try await withCheckedThrowingContinuation({ continuation in
            DispatchQueue.main.async {
                let installer = VZMacOSInstaller(virtualMachine: self.virtualMachine, restoringFromImageAt: restoreImageURL)

                NSLog("Starting installation.")
                installer.install(completionHandler: { (result: Result<Void,Error>) in
                    if case let .failure(error) = result {
                        continuation.resume(throwing: error)
                    } else {
                        NSLog("Installation succeeded.")
                        continuation.resume(returning: ())
                    }
                })

                // Observe installation progress
                self.installationObserver = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { (progress, change) in
                    NSLog("Installation progress: \(change.newValue! * 100).")
                }
            }
        })
    }
    
    
    private func setupVirtualMachine(vmModel: VMModel, macOSConfiguration: VZMacOSConfigurationRequirements) async throws {
        return try await withCheckedThrowingContinuation({ continuation in
            let virtualMachineConfiguration = VZVirtualMachineConfiguration()

            // platform
            do {
                let macPlatformConfiguration = VZMacPlatformConfiguration()
                let auxiliaryStorage = try VZMacAuxiliaryStorage(creatingStorageAt: vmModel.auxiliaryStorageURL, hardwareModel: macOSConfiguration.hardwareModel, options: [])
                
                macPlatformConfiguration.auxiliaryStorage = auxiliaryStorage
                macPlatformConfiguration.hardwareModel = macOSConfiguration.hardwareModel
                macPlatformConfiguration.machineIdentifier = VZMacMachineIdentifier()
    
                // Store the hardware model and machine identifier to disk so that we
                // can retrieve them for subsequent boots.
                try macPlatformConfiguration.hardwareModel.dataRepresentation.write(to: vmModel.hardwareModelURL)
                try macPlatformConfiguration.machineIdentifier.dataRepresentation.write(to: vmModel.machineIdentifierURL)
                
                virtualMachineConfiguration.platform = macPlatformConfiguration
            } catch {
                continuation.resume(throwing: error)
                return
            }
            
            // cpu
            virtualMachineConfiguration.cpuCount = vmModel.config.cpu.count
            if virtualMachineConfiguration.cpuCount < macOSConfiguration.minimumSupportedCPUCount {
                continuation.resume(throwing: VMOSError.regularFailure("CPUCount isn't supported by the macOS configuration."))
                return
            }
            
            // memory
            virtualMachineConfiguration.memorySize = vmModel.config.memory.size
            if virtualMachineConfiguration.memorySize < macOSConfiguration.minimumSupportedMemorySize {
                continuation.resume(throwing: VMOSError.regularFailure("memorySize isn't supported by the macOS configuration. required \(virtualMachineConfiguration.memorySize) , minimum \(macOSConfiguration.minimumSupportedMemorySize)"))
                return
            }
            
            // bootLoader
            virtualMachineConfiguration.bootLoader = VZMacOSBootLoader()
            
            // graphicsDevices
            virtualMachineConfiguration.graphicsDevices = vmModel.config.graphicsDevices.map({$0.createConfiguration()})
            
            // storageDevices
            virtualMachineConfiguration.storageDevices = []
            for item in vmModel.config.storageDevices {
                let result = item.createConfiguration(rootPath: vmModel.rootPath)
                switch result {
                case .failure(let error):
                    continuation.resume(throwing: VMOSError.regularFailure(error))
                    return
                case .success(let configItem):
                    virtualMachineConfiguration.storageDevices.append(configItem)
                }
            }
            
            // networkDevices
            virtualMachineConfiguration.networkDevices = vmModel.config.networkDevices.map({$0.createConfiguration()})
            
            // pointingDevices
            virtualMachineConfiguration.pointingDevices = vmModel.config.pointingDevices.map({$0.createConfiguration()})
            
            // audioDevices
            virtualMachineConfiguration.audioDevices = vmModel.config.audioDevices.map({$0.createConfiguration()})
            
            // Validate
            do {
                try virtualMachineConfiguration.validate()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            
            // Create
            virtualMachine = VZVirtualMachine(configuration: virtualMachineConfiguration)
            virtualMachineResponder = VMOSCreatorForMacOSDelegate()
            virtualMachine.delegate = virtualMachineResponder

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
    
    
    private func createVMBundle(path: URL) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let bundleFd = mkdir(path.path(percentEncoded: false), S_IRWXU | S_IRWXG | S_IRWXO)
            if bundleFd == -1 {
                if errno == EEXIST {
                    let error = "Failed to create VM.bundle: the base directory already exists."
                    continuation.resume(throwing: VMOSError.regularFailure(error))
                    return
                }
                continuation.resume(throwing: VMOSError.regularFailure("Failed to create VM.bundle."))
                return
            }

            let result = close(bundleFd)
            if result != 0 {
                continuation.resume(throwing: VMOSError.regularFailure("Failed to close VM.bundle."))
                return
            }
            continuation.resume(returning: ())
        }
    }
}
