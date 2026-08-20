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
    weak var runtimeState: VMRuntimeState?
    
    // internal
    private var virtualMachineView: VZVirtualMachineView!
    private var virtualMachineResponder: VMOSInternalVirtualMachineDelegate?
    private var virtualMachine: VZVirtualMachine!
    private var screenshotTimer: Timer?
    // Keep the controller alive while a window-close save is still running.
    private var shutdownRetainer: VMOSInternalVirtualMachineViewController?
    

    public override func loadView() {
        view = NSView()
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        // Do view setup here.
        
        virtualMachineView = VZVirtualMachineView()
        virtualMachineView.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 14.0, *) {
            virtualMachineView.automaticallyReconfiguresDisplay = true
        }
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
        runtimeState?.update(.preparing)
        
        // load model from path
        guard let rootPath = rootPath else {
            fail("The virtual machine location is unavailable.")
            return
        }
        
        if !FileManager.default.fileExists(atPath: rootPath.path(percentEncoded: false)) {
            fail("The virtual machine bundle is missing at \(rootPath.path(percentEncoded: false)).")
            return
        }
        
        let modelResult = VMModel.loadConfigFromFile(rootPath: rootPath)
        if case let .failure(error) = modelResult {
            fail("Could not load the virtual machine: \(error)")
            return
        }
        
        guard case let .success(model) = modelResult else {
            fail("Could not read the virtual machine configuration.")
            return
        }
        
        let runner = VMOSRunnerFactory.getRunner(model.config.type)
        
        let virtualMachineConfigurationResult = runner.createConfiguration(model: model)
        if case let .failure(error) = virtualMachineConfigurationResult {
            fail("Could not create the virtual machine configuration: \(error)")
            return
        }
        guard case let .success(virtualMachineConfiguration) = virtualMachineConfigurationResult else {
            fail("Could not create the virtual machine configuration.")
            return
        }
        
        virtualMachine = VZVirtualMachine(configuration: virtualMachineConfiguration)
        virtualMachineResponder = VMOSInternalVirtualMachineDelegate(rootPath: rootPath)
        virtualMachine.delegate = virtualMachineResponder
        virtualMachineView.virtualMachine = virtualMachine


        if recoveryMode {
            runtimeState?.update(.starting)
            let startOptions = VZMacOSVirtualMachineStartOptions()
            startOptions.startUpFromMacOSRecovery = true
            virtualMachine.start(options: startOptions) { error in
                if let error = error {
                    Task { @MainActor in self.fail("Could not start macOS Recovery: \(error.localizedDescription)") }
                    return
                }

                // succeed start
                Task { @MainActor in
                    self.runtimeState?.update(.running)
                    VMRunningRegistry.shared.markRunning(rootPath: rootPath)
                    self.startScreenshotTimer()
                }
            }
        } else {
            if #available(macOS 14.0, *), FileManager.default.fileExists(atPath: model.savedMachineStateURL.path(percentEncoded: false)) {
                restoreMachine(from: model.savedMachineStateURL, rootPath: rootPath, model: model)
                return
            }

            startNormally(rootPath: rootPath, model: model)
        }
    }

    @available(macOS 14.0, *)
    private func restoreMachine(from stateURL: URL, rootPath: URL, model: VMModel) {
        runtimeState?.update(.restoring)
        virtualMachine.restoreMachineStateFrom(url: stateURL) { [weak self] error in
            guard let self else { return }
            if let error {
                try? FileManager.default.removeItem(at: stateURL)
                Task { @MainActor in
                    self.runtimeState?.update(.starting)
                    self.startNormally(rootPath: rootPath, model: model)
                }
                print("saved state restore failed, starting normally: \(error)")
                return
            }
            self.virtualMachine.resume { result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        try? FileManager.default.removeItem(at: stateURL)
                        self.runtimeState?.update(.running)
                        VMRunningRegistry.shared.markRunning(rootPath: rootPath)
                        self.startScreenshotTimer()
                    case .failure(let error):
                        self.fail("Could not resume the saved virtual machine: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func startNormally(rootPath: URL, model: VMModel) {
        runtimeState?.update(.starting)
        if #available(macOS 27.0, *),
           model.config.type == .macOS {
            switch VMGuestProvisioningCredentialStore.load(vmRootPath: rootPath) {
            case .failure(let error):
                fail(error)
                return
            case .success(let credential?):
                do {
                    let provisioning = VZMacGuestProvisioningOptions()
                    provisioning.fullName = credential.fullName
                    provisioning.username = credential.username
                    provisioning.password = credential.password
                    provisioning.logsInAutomatically = credential.logsInAutomatically
                    provisioning.enablesRemoteLogin = credential.enablesRemoteLogin
                    let options = VZMacOSVirtualMachineStartOptions()
                    try options.setGuestProvisioning(provisioning)
                    virtualMachine.start(options: options) { [weak self] error in
                        Task { @MainActor in
                            guard let self else { return }
                            if let error {
                                self.fail("Could not start the provisioned virtual machine: \(error.localizedDescription)")
                            } else {
                                VMGuestProvisioningCredentialStore.delete(vmRootPath: rootPath)
                                self.didStart(rootPath: rootPath)
                            }
                        }
                    }
                    return
                } catch {
                    fail("Guest provisioning settings were rejected: \(error.localizedDescription)")
                    return
                }
            case .success(nil):
                break
            }
        }

        virtualMachine.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.didStart(rootPath: rootPath)
                case .failure(let error):
                    self.fail("Could not start the virtual machine: \(error.localizedDescription)")
                }
            }
        }
    }

    private func didStart(rootPath: URL) {
        runtimeState?.update(.running)
        VMRunningRegistry.shared.markRunning(rootPath: rootPath)
        startScreenshotTimer()
    }

    func pauseMachine() {
        guard virtualMachine?.canPause == true else { return }
        runtimeState?.update(.pausing)
        virtualMachine.pause { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success: self.runtimeState?.update(.paused)
                case .failure(let error): self.fail("Could not pause the virtual machine: \(error.localizedDescription)")
                }
            }
        }
    }

    func resumeMachine() {
        guard virtualMachine?.canResume == true else { return }
        virtualMachine.resume { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success: self.runtimeState?.update(.running)
                case .failure(let error): self.fail("Could not resume the virtual machine: \(error.localizedDescription)")
                }
            }
        }
    }

    func requestStopMachine() {
        guard virtualMachine?.canRequestStop == true else { return }
        runtimeState?.update(.stopping)
        do {
            try virtualMachine.requestStop()
        } catch {
            fail("The guest did not accept the shutdown request: \(error.localizedDescription)")
        }
    }

    func saveAndStopMachine() {
        guard #available(macOS 14.0, *), let rootPath else {
            requestStopMachine()
            return
        }
        let stateURL = rootPath.appending(path: "MachineState.vzvmsave")
        let save = { [weak self] in
            guard let self else { return }
            self.shutdownRetainer = self
            self.runtimeState?.update(.saving)
            try? FileManager.default.removeItem(at: stateURL)
            self.virtualMachine.saveMachineStateTo(url: stateURL) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.fail("Could not save the virtual machine state: \(error.localizedDescription)")
                    } else {
                        self.runtimeState?.update(.stopped)
                        VMRunningRegistry.shared.markStopped(rootPath: rootPath)
                    }
                    self.shutdownRetainer = nil
                }
            }
        }

        if virtualMachine.state == .paused {
            save()
        } else if virtualMachine.canPause {
            runtimeState?.update(.pausing)
            virtualMachine.pause { [weak self] result in
                switch result {
                case .success: save()
                case .failure(let error):
                    Task { @MainActor in self?.fail("Could not pause before saving: \(error.localizedDescription)") }
                }
            }
        }
    }

    func prepareForWindowClose() {
        screenshotTimer?.invalidate()
        screenshotTimer = nil
        captureScreenshot()
        guard let rootPath else { return }
        if runtimeState?.phase == .running || runtimeState?.phase == .paused {
            saveAndStopMachine()
        } else {
            VMRunningRegistry.shared.markStopped(rootPath: rootPath)
        }
    }

    private func fail(_ message: String) {
        runtimeState?.update(.failed(message))
        if let rootPath {
            VMRunningRegistry.shared.markStopped(rootPath: rootPath)
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
        NotificationCenter.default.post(name: AppConfigManager.newVMChangedNotification, object: nil)
    }

}

extension VMOSInternalVirtualMachineViewController: VZVirtualMachineDelegate {
    
    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        runtimeState?.update(.stopped)
        if let rootPath { VMRunningRegistry.shared.markStopped(rootPath: rootPath) }
    }
    
    
    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        
        fail("The virtual machine stopped unexpectedly: \(error.localizedDescription)")
    }
    
    public func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: Error) {
        
        print("network device \(networkDevice) error : \(error)")
    }
}

#endif
