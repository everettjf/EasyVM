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
    private var virtualMachine: VZVirtualMachine!
    private var configuredMemorySize: UInt64 = 0
    private var screenshotTimer: Timer?
    private var guestAgentClient: VMGuestAgentHostClient?
    private var runLease: VMRunLease?
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

        guard let lease = VMRunningRegistry.shared.acquire(rootPath: rootPath) else {
            fail("This virtual machine is already starting or running in another window.")
            return
        }
        runLease = lease

        if case let .failure(error) = VMSnapshotManager.recoverInterruptedRestore(vmRootPath: rootPath) {
            fail(error)
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
        
        configuredMemorySize = virtualMachineConfiguration.memorySize
        virtualMachine = VZVirtualMachine(configuration: virtualMachineConfiguration)
        // This controller owns the complete runtime lifecycle. Routing delegate
        // callbacks elsewhere would clear the registry without transitioning
        // the scene to `.stopped`, leaving an unusable stopped window alive.
        virtualMachine.delegate = self
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
                    self.markMachineRunning()
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
                EasyVMLog.error("Saved state restore failed; falling back to normal boot: \(error.localizedDescription)")
                return
            }
            self.virtualMachine.resume { result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        try? FileManager.default.removeItem(at: stateURL)
                        self.runtimeState?.update(.running)
                        self.markMachineRunning()
                        self.startScreenshotTimer()
                        self.startGuestAgent(model: model)
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
                                self.didStart(rootPath: rootPath, model: model)
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
                    self.didStart(rootPath: rootPath, model: model)
                case .failure(let error):
                    self.fail("Could not start the virtual machine: \(error.localizedDescription)")
                }
            }
        }
    }

    private func didStart(rootPath: URL, model: VMModel) {
        runtimeState?.update(.running)
        markMachineRunning()
        if let smokeTest = VMReleaseSmokeTest.configuration(for: rootPath) {
            finishReleaseSmokeTest(smokeTest)
            return
        }
        startScreenshotTimer()
        updateBalloonMemoryState()
        startGuestAgent(model: model)
    }

    private func finishReleaseSmokeTest(_ configuration: VMReleaseSmokeTestConfiguration) {
        virtualMachine.stop { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    VMReleaseSmokeTest.report("failed: stop: \(error.localizedDescription)", configuration: configuration)
                    self.fail("Release smoke VM started but could not stop: \(error.localizedDescription)")
                    return
                }
                self.runtimeState?.update(.stopped)
                self.releaseRunLease()
                VMReleaseSmokeTest.report("started-and-stopped", configuration: configuration)
                NSApplication.shared.terminate(nil)
            }
        }
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

    func setBalloonMemory(fraction: Double) {
        guard let device = virtualMachine?.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice else { return }
        let maximum = configuredMemorySize
        let requested = UInt64(Double(maximum) * min(max(fraction, 0), 1))
        device.targetVirtualMachineMemorySize = requested
        runtimeState?.updateBalloonMemory(target: device.targetVirtualMachineMemorySize, maximum: maximum)
    }

    private func updateBalloonMemoryState() {
        guard let device = virtualMachine?.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice else {
            runtimeState?.updateBalloonMemory(target: nil, maximum: nil)
            return
        }
        runtimeState?.updateBalloonMemory(
            target: device.targetVirtualMachineMemorySize,
            maximum: configuredMemorySize
        )
    }

    func requestStopMachine() {
        guard virtualMachine?.canRequestStop == true else { return }
        runtimeState?.update(.stopping)
        markMachineStopping()
        do {
            try virtualMachine.requestStop()
        } catch {
            fail("The guest did not accept the shutdown request: \(error.localizedDescription)")
        }
    }

    func forceStopMachine() {
        guard virtualMachine != nil else {
            releaseRunLease()
            runtimeState?.update(.stopped)
            return
        }
        runtimeState?.update(.stopping)
        markMachineStopping()
        virtualMachine.stop { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.fail("Could not force stop the virtual machine: \(error.localizedDescription)")
                } else {
                    self.runtimeState?.update(.stopped)
                    self.releaseRunLease()
                }
            }
        }
    }

    func saveAndStopMachine() {
        guard #available(macOS 14.0, *), let rootPath else {
            requestStopMachine()
            return
        }
        markMachineStopping()
        shutdownRetainer = self
        saveMachineStateAndStop(rootPath: rootPath)
    }

    func saveAndStopForWindowClose() {
        screenshotTimer?.invalidate()
        screenshotTimer = nil
        captureScreenshot(synchronously: true)
        saveAndStopMachine()
    }

    @available(macOS 14.0, *)
    private func saveMachineStateAndStop(rootPath: URL) {
        let stateURL = rootPath.appending(path: "MachineState.vzvmsave")
        let save = { [weak self] in
            guard let self else { return }
            self.runtimeState?.update(.saving)
            let pendingURL: URL
            do {
                pendingURL = try VMSavedStateStore.prepare(stateURL: stateURL)
            } catch {
                self.fail("Could not prepare the saved-state transaction: \(error.localizedDescription)")
                self.shutdownRetainer = nil
                return
            }
            self.virtualMachine.saveMachineStateTo(url: pendingURL) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        VMSavedStateStore.discardPending(stateURL: stateURL)
                        self.fail("Could not save the virtual machine state: \(error.localizedDescription)")
                    } else {
                        do {
                            try VMSavedStateStore.commit(pendingURL: pendingURL, stateURL: stateURL)
                            self.runtimeState?.update(.stopped)
                            self.releaseRunLease()
                        } catch {
                            VMSavedStateStore.discardPending(stateURL: stateURL)
                            self.fail("Could not commit the saved machine state: \(error.localizedDescription)")
                        }
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
                    Task { @MainActor in
                        self?.fail("Could not pause before saving: \(error.localizedDescription)")
                        self?.shutdownRetainer = nil
                    }
                }
            }
        } else {
            shutdownRetainer = nil
        }
    }

    func prepareForWindowClose() {
        stopGuestAgent()
        screenshotTimer?.invalidate()
        screenshotTimer = nil
        captureScreenshot(synchronously: true)
        guard rootPath != nil else { return }
        if runtimeState?.phase == .running || runtimeState?.phase == .paused {
            saveAndStopMachine()
        } else {
            releaseRunLease()
        }
    }

    private func fail(_ message: String) {
        stopGuestAgent()
        runtimeState?.update(.failed(message))
        releaseRunLease()
        if let rootPath, let smokeTest = VMReleaseSmokeTest.configuration(for: rootPath) {
            VMReleaseSmokeTest.report("failed: \(message)", configuration: smokeTest)
        }
    }

    private func markMachineRunning() {
        guard let runLease else { return }
        VMRunningRegistry.shared.transition(runLease, to: .running)
    }

    private func markMachineStopping() {
        guard let runLease else { return }
        VMRunningRegistry.shared.transition(runLease, to: .stopping)
    }

    private func releaseRunLease() {
        guard let runLease else { return }
        VMRunningRegistry.shared.release(runLease)
        self.runLease = nil
    }

    // keep a thumbnail of the running system for the machine card
    private func startScreenshotTimer() {
        screenshotTimer?.invalidate()
        screenshotTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.captureScreenshot()
        }
        screenshotTimer?.tolerance = 10
    }

    private func startGuestAgent(model: VMModel) {
        guard model.config.type == .linux,
              (model.config.linuxFeatures ?? .legacy).virtioSocketEnabled else {
            runtimeState?.updateGuestAgent(.unavailable)
            return
        }
        guard let device = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
            runtimeState?.updateGuestAgent(.unavailable)
            return
        }
        guard let identifier = try? Data(contentsOf: model.machineIdentifierURL) else {
            runtimeState?.updateGuestAgent(.disconnected("The VM machine identifier is unreadable."))
            return
        }
        switch VMGuestAgentEnrollmentStore.load(machineIdentifierData: identifier) {
        case .failure(let error):
            runtimeState?.updateGuestAgent(.disconnected(error))
        case .success(nil):
            runtimeState?.updateGuestAgent(.notEnrolled)
        case .success(let enrollment?):
            guard let runtimeState else { return }
            let client = VMGuestAgentHostClient(device: device, enrollment: enrollment, runtimeState: runtimeState)
            guestAgentClient = client
            client.start()
        }
    }

    private func stopGuestAgent() {
        guestAgentClient?.stop()
        guestAgentClient = nil
    }

    func sendGuestAgentCommand(_ operation: VMGuestAgentOperation) {
        guestAgentClient?.send(operation)
    }

    func uploadToGuest(localURL: URL, destinationPath: String, overwrite: Bool) {
        guestAgentClient?.upload(localURL: localURL, destinationPath: destinationPath, overwrite: overwrite)
    }

    func downloadFromGuest(sourcePath: String, destinationURL: URL) {
        guestAgentClient?.download(sourcePath: sourcePath, destinationURL: destinationURL)
    }

    func cancelGuestAgentTransfer() {
        guestAgentClient?.cancelTransfer()
    }

    private func captureScreenshot(synchronously: Bool = false) {
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
        let capturedImage = NSImage(size: bounds.size)
        capturedImage.addRepresentation(rep)

        let maximumWidth: CGFloat = 720
        let scale = min(1, maximumWidth / max(bounds.width, 1))
        let thumbnailSize = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let thumbnail = NSImage(size: thumbnailSize)
        thumbnail.lockFocus()
        capturedImage.draw(in: NSRect(origin: .zero, size: thumbnailSize))
        thumbnail.unlockFocus()
        guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let pngData = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        let destination = rootPath.appending(path: "screenshot.png")
        if let pngData, synchronously {
            do {
                try pngData.write(to: destination, options: .atomic)
                NotificationCenter.default.post(name: AppConfigManager.newVMChangedNotification, object: nil)
            } catch {
                EasyVMLog.error("Failed to save VM thumbnail: \(error.localizedDescription)", logger: EasyVMLog.storage)
            }
        } else if let pngData {
            Task.detached(priority: .utility) {
                do {
                    try pngData.write(to: destination, options: .atomic)
                    await MainActor.run {
                        NotificationCenter.default.post(name: AppConfigManager.newVMChangedNotification, object: nil)
                    }
                } catch {
                    EasyVMLog.error("Failed to save VM thumbnail: \(error.localizedDescription)", logger: EasyVMLog.storage)
                }
            }
        }
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
    }

}

extension VMOSInternalVirtualMachineViewController: VZVirtualMachineDelegate {
    
    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        stopGuestAgent()
        runtimeState?.update(.stopped)
        releaseRunLease()
    }
    
    
    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        
        fail("The virtual machine stopped unexpectedly: \(error.localizedDescription)")
    }
    
    public func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: Error) {
        
        EasyVMLog.error("Network device disconnected: \(error.localizedDescription)", logger: EasyVMLog.network)
    }
}

#endif
