//
//  VMOSRunnerForLinux.swift
//  EZVM
//
//  Created by everettjf on 2022/10/5.
//

import Foundation
import Virtualization

#if arch(arm64)
class VMOSRunnerForLinux : VMOSRunner {
    
    
    func createConfiguration(
        model: VMModel,
        graphicsBackend: (any VMGraphicsBackend)? = nil
    ) -> VMOSResult<VZVirtualMachineConfiguration, String> {
        
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
        if let directBoot = createDiagnosticDirectBootLoader() {
            virtualMachineConfiguration.bootLoader = directBoot
        } else {
            let bootLoaderResult = createBootLoader(model: model)
            switch bootLoaderResult {
            case .failure(let error):
                return .failure(error)
            case .success(let bootLoader):
                virtualMachineConfiguration.bootLoader = bootLoader
            }
        }
        
        // graphicsDevices
        let graphicsBackend = graphicsBackend ?? VMAppleGraphicsBackend()
        if case let .failure(error) = graphicsBackend.applyGraphics(
            from: model.config.graphicsDevices,
            to: virtualMachineConfiguration
        ) {
            return .failure(error)
        }
        
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

        if (model.config.linuxFeatures ?? .legacy).virtioSocketEnabled {
            guard !model.config.directorySharingDevices.contains(where: {
                $0.tag == VMGuestAgentEnrollmentStore.sharedDirectoryTag
            }) else {
                return .failure("The directory-sharing tag '\(VMGuestAgentEnrollmentStore.sharedDirectoryTag)' is reserved for the EZVM guest agent.")
            }
            guard let identifier = try? Data(contentsOf: model.machineIdentifierURL) else {
                return .failure("Could not read the machine identifier for guest-agent enrollment.")
            }
            switch VMGuestAgentEnrollmentStore.prepareSharedConfiguration(
                machineIdentifierData: identifier,
                directoryURL: model.guestAgentEnrollmentDirectoryURL
            ) {
            case .failure(let error):
                return .failure(error)
            case .success:
                let directory = VZSharedDirectory(
                    url: model.guestAgentEnrollmentDirectoryURL,
                    readOnly: true
                )
                let share = VZSingleDirectoryShare(directory: directory)
                let device = VZVirtioFileSystemDeviceConfiguration(
                    tag: VMGuestAgentEnrollmentStore.sharedDirectoryTag
                )
                device.share = share
                virtualMachineConfiguration.directorySharingDevices.append(device)
            }
        }

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

    /// A deliberately explicit local-test escape hatch for validating kernels,
    /// initramfs changes, and guest drivers in the complete EZVM runtime. It is
    /// ignored by normal GUI launches and never changes a machine's config.
    private func createDiagnosticDirectBootLoader() -> VZLinuxBootLoader? {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("--ezvm-headless") || VMReleaseSmokeTest.configuration() != nil,
              let kernelPath = process.environment["EZVM_EXPERIMENTAL_LINUX_KERNEL"],
              let commandLine = process.environment["EZVM_EXPERIMENTAL_LINUX_COMMAND_LINE"],
              !kernelPath.isEmpty, !commandLine.isEmpty else { return nil }

        let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: kernelPath))
        if let initrdPath = process.environment["EZVM_EXPERIMENTAL_LINUX_INITRD"],
           !initrdPath.isEmpty {
            bootLoader.initialRamdiskURL = URL(fileURLWithPath: initrdPath)
        }
        bootLoader.commandLine = commandLine
        return bootLoader
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
                 && UserDefaults.standard.bool(forKey: EZVMExperimentalFeatures.efiSecureBootKey)) {
                return .failure("UEFI Secure Boot requires macOS 27 and the EFI Secure Boot experimental feature in Settings.")
            }
            if #available(macOS 27.0, *),
               UserDefaults.standard.bool(forKey: EZVMExperimentalFeatures.efiSecureBootKey),
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
