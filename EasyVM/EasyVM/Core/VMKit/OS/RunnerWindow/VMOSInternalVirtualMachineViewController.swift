//
//  VMOSInternalViewController.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import Cocoa
import Foundation
import Virtualization


#if arch(arm64)

public class VMOSInternalVirtualMachineViewController: NSViewController {
    // parameters
    var rootPath: URL? = nil
    var recoveryMode: Bool = false
    
    // internal
    private var virtualMachineView: VZVirtualMachineView!
    private var virtualMachineResponder: VMOSInternalVirtualMachineDelegate?
    private var virtualMachine: VZVirtualMachine!
    private var screenshotTimer: Timer?
    

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
        
        let runner = VMOSRunnerFactory.getRunner(model.config.type)
        
        let virtualMachineConfigurationResult = runner.createConfiguration(model: model)
        if case let .failure(error) = virtualMachineConfigurationResult {
            print("failed create configuration : \(error)")
            return
        }
        guard case let .success(virtualMachineConfiguration) = virtualMachineConfigurationResult else {
            print("failed create configuration")
            return
        }
        
        virtualMachine = VZVirtualMachine(configuration: virtualMachineConfiguration)
        virtualMachineResponder = VMOSInternalVirtualMachineDelegate(rootPath: rootPath)
        virtualMachine.delegate = virtualMachineResponder
        virtualMachineView.virtualMachine = virtualMachine


        if recoveryMode {
            let startOptions = VZMacOSVirtualMachineStartOptions()
            startOptions.startUpFromMacOSRecovery = true
            virtualMachine.start(options: startOptions) { error in
                if let error = error {
                    print("error start : \(error)")
                    return
                }

                // succeed start
                print("Virtual machine successfully started.")
                Task { @MainActor in
                    VMRunningRegistry.shared.markRunning(rootPath: rootPath)
                    self.startScreenshotTimer()
                }
            }
        } else {
            virtualMachine.start { result in
                if case let .failure(error) = result {
                    print("error start : \(error)")
                    return
                }

                // succeed start
                print("Virtual machine successfully started.")
                Task { @MainActor in
                    VMRunningRegistry.shared.markRunning(rootPath: rootPath)
                    self.startScreenshotTimer()
                }
            }
        }
    }

    // keep a thumbnail of the running system for the machine card
    private func startScreenshotTimer() {
        screenshotTimer?.invalidate()
        screenshotTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.captureScreenshot()
        }
    }

    private func captureScreenshot() {
        guard let rootPath = rootPath, let view = virtualMachineView else {
            return
        }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            return
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return
        }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        MacKitUtil.saveImage(image, atUrl: rootPath.appending(path: "screenshot.png"))
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        // closing the window tears the virtual machine down with it
        screenshotTimer?.invalidate()
        screenshotTimer = nil
        captureScreenshot()
        if let rootPath = rootPath {
            Task { @MainActor in
                VMRunningRegistry.shared.markStopped(rootPath: rootPath)
                // refresh the machine list so the card shows the final thumbnail
                NotificationCenter.default.post(name: AppConfigManager.newVMChangedNotification, object: nil)
            }
        }
    }

}

extension VMOSInternalVirtualMachineViewController: VZVirtualMachineDelegate {
    
    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        
        print("guest did stop")
    }
    
    
    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        
        print("did stop with error : \(error)")
    }
    
    public func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: Error) {
        
        print("network device \(networkDevice) error : \(error)")
    }
}

#endif
