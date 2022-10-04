//
//  VMOSInternalViewController.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import Cocoa
import Foundation
import Virtualization


class VMOSInternalVirtualMachineDelegate: NSObject, VZVirtualMachineDelegate {
    
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let info = "!! Virtual machine did stop with error: \(error.localizedDescription)"
        print(info)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        let info = "!! Guest did stop virtual machine."
        print(info)
    }
}

public class VMOSInternalVirtualMachineViewController: NSViewController {
    // parameters
    var rootPath: URL? = nil
    
    // internal
    private var virtualMachineView: VZVirtualMachineView!
    private var virtualMachineResponder: VMOSInternalVirtualMachineDelegate?
    private var virtualMachine: VZVirtualMachine!
    

    public override func loadView() {
        view = NSView()
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        // Do view setup here.
        
        virtualMachineView = VZVirtualMachineView()
        view.addSubview(virtualMachineView)
        
        NSLayoutConstraint.activate([
            virtualMachineView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            virtualMachineView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            virtualMachineView.topAnchor.constraint(equalTo: view.topAnchor),
            virtualMachineView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        DispatchQueue.main.async {
            self.startMachine()
        }
    }
    
    private func startMachine() {
        
        // load model from path
        guard let rootPath = rootPath else {
            print("root path is nil")
            return
        }
        
        if !FileManager.default.fileExists(atPath: rootPath.path(percentEncoded: false)) {
            print("Missing Virtual Machine Bundle at \(rootPath.path(percentEncoded: false)). Run InstallationTool first to create it.")
            return
        }
        
        let modelResult = VMModel.loadConfigFromFile(rootPath: rootPath)
        if case let .failure(error) = modelResult {
            print("error load model : \(error)")
            return
        }
        
        guard case let .success(model) = modelResult else {
            print("can not get model")
            return
        }
        
        let virtualMachineConfigurationResult = createVirtualMachineConfiguration(model: model)
        if case let .failure(error) = virtualMachineConfigurationResult {
            print("failed create configuration : \(error)")
            return
        }
        guard case let .success(virtualMachineConfiguration) = virtualMachineConfigurationResult else {
            print("failed create configuration")
            return
        }
        
        virtualMachine = VZVirtualMachine(configuration: virtualMachineConfiguration)
        virtualMachineResponder = VMOSInternalVirtualMachineDelegate()
        virtualMachine.delegate = virtualMachineResponder
        virtualMachineView.virtualMachine = virtualMachine
        
        let startOptions = VZMacOSVirtualMachineStartOptions()
        startOptions.startUpFromMacOSRecovery = false
        
        virtualMachine.start(options: startOptions) { error in
            if let error = error {
                print("error start : \(error)")
                return
            }

            // succeed start
            print("Virtual machine successfully started.")
        }
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

    
    private func createVirtualMachineConfiguration(model: VMModel) -> VMOSResult<VZVirtualMachineConfiguration, String> {
        
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
        
        // Validate
        do {
            try virtualMachineConfiguration.validate()
        } catch {
            return .failure("failed to validate : \(error)")
        }
        
        return .success(virtualMachineConfiguration)
    }
    
}
