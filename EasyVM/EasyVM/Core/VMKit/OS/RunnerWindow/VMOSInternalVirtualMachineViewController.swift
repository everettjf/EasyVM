//
//  VMOSInternalViewController.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import Cocoa
import Foundation
import Virtualization
import AccessoryAccess


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
    private var usbAccessoryCoordinator: AnyObject?
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
        markMachineRunning()
        startScreenshotTimer()
        startUSBAccessoryDiscoveryIfEnabled()
        updateBalloonMemoryState()
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
        stopUSBAccessoryDiscovery { [weak self] in
            guard let self else { return }
            self.virtualMachine.stop { error in
                Task { @MainActor in
                    if let error {
                        self.fail("Could not force stop the virtual machine: \(error.localizedDescription)")
                    } else {
                        self.runtimeState?.update(.stopped)
                        self.releaseRunLease()
                    }
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
        stopUSBAccessoryDiscovery { [weak self] in
            self?.saveMachineStateAndStop(rootPath: rootPath)
        }
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
            try? FileManager.default.removeItem(at: stateURL)
            self.virtualMachine.saveMachineStateTo(url: stateURL) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.fail("Could not save the virtual machine state: \(error.localizedDescription)")
                    } else {
                        self.runtimeState?.update(.stopped)
                        self.releaseRunLease()
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
        screenshotTimer?.invalidate()
        screenshotTimer = nil
        captureScreenshot(synchronously: true)
        guard rootPath != nil else { return }
        if runtimeState?.phase == .running || runtimeState?.phase == .paused {
            saveAndStopMachine()
        } else {
            stopUSBAccessoryDiscovery()
            releaseRunLease()
        }
    }

    private func fail(_ message: String) {
        stopUSBAccessoryDiscovery()
        runtimeState?.update(.failed(message))
        releaseRunLease()
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

extension VMOSInternalVirtualMachineViewController {
    func toggleUSBAccessory(registryID: UInt64) {
        guard #available(macOS 27.0, *), let coordinator = usbAccessoryCoordinator as? VMUSBAccessoryCoordinator else {
            runtimeState?.updateUSBAccessories([], statusMessage: "USB passthrough requires macOS 27.")
            return
        }
        coordinator.toggle(registryID: registryID)
    }

    private func startUSBAccessoryDiscoveryIfEnabled() {
        guard #available(macOS 27.0, *),
              UserDefaults.standard.bool(forKey: EasyVMExperimentalFeatures.usbPassthroughKey),
              let virtualMachine,
              let controller = virtualMachine.usbControllers.first else { return }
        let coordinator = VMUSBAccessoryCoordinator(controller: controller) { [weak self] items, message in
            self?.runtimeState?.updateUSBAccessories(items, statusMessage: message)
        }
        usbAccessoryCoordinator = coordinator
        coordinator.start()
    }

    private func stopUSBAccessoryDiscovery(completion: @escaping () -> Void = {}) {
        guard #available(macOS 27.0, *), let coordinator = usbAccessoryCoordinator as? VMUSBAccessoryCoordinator else {
            completion()
            return
        }
        usbAccessoryCoordinator = nil
        runtimeState?.updateUSBAccessories([], statusMessage: nil)
        coordinator.stopAndDetach(completion: completion)
    }
}

@available(macOS 27.0, *)
private final class VMUSBAccessoryCoordinator: NSObject, AAUSBAccessoryListener, VZUSBController.Delegate {
    typealias UpdateHandler = ([VMRuntimeState.USBAccessoryItem], String?) -> Void

    private let controller: VZUSBController
    private let updateHandler: UpdateHandler
    private var accessories: [UInt64: AAUSBAccessory] = [:]
    private var attachedDevices: [UInt64: VZUSBPassthroughDevice] = [:]
    private var isRegistered = false
    private var isStopping = false

    init(controller: VZUSBController, updateHandler: @escaping UpdateHandler) {
        self.controller = controller
        self.updateHandler = updateHandler
        super.init()
        controller.delegate = self
    }

    func start() {
        AAUSBAccessoryManager.shared.registerListener(self, matchingCriteria: []) { [weak self] accessories, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.publish(message: "USB access failed: \(error.localizedDescription)")
                    return
                }
                self.isRegistered = true
                if self.isStopping {
                    AAUSBAccessoryManager.shared.unregisterListener(self) {}
                    self.isRegistered = false
                    return
                }
                self.accessories = Dictionary(uniqueKeysWithValues: accessories.map { ($0.registryID, $0) })
                self.publish()
            }
        }
    }

    func stopAndDetach(completion: @escaping () -> Void) {
        isStopping = true
        controller.delegate = nil
        if isRegistered {
            AAUSBAccessoryManager.shared.unregisterListener(self) {}
            isRegistered = false
        }

        let devices = Array(attachedDevices.values)
        guard !devices.isEmpty else {
            completion()
            return
        }
        let group = DispatchGroup()
        for device in devices {
            group.enter()
            controller.detach(device: device) { [weak self] _ in
                if let self, let entry = self.attachedDevices.first(where: { $0.value === device }) {
                    self.attachedDevices.removeValue(forKey: entry.key)
                }
                group.leave()
            }
        }
        group.notify(queue: .main, execute: completion)
    }

    func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        DispatchQueue.main.async { [weak self] in
            guard self?.isStopping == false else { return }
            self?.accessories[usbAccessory.registryID] = usbAccessory
            self?.publish()
        }
    }

    func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        DispatchQueue.main.async { [weak self] in
            guard self?.isStopping == false else { return }
            self?.accessories.removeValue(forKey: usbAccessory.registryID)
            self?.attachedDevices.removeValue(forKey: usbAccessory.registryID)
            self?.publish()
        }
    }

    func toggle(registryID: UInt64) {
        if let device = attachedDevices[registryID] {
            controller.detach(device: device) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.publish(message: "Could not detach USB device: \(error.localizedDescription)")
                } else {
                    self.attachedDevices.removeValue(forKey: registryID)
                    self.publish()
                }
            }
            return
        }

        guard let accessory = accessories[registryID] else {
            publish(message: "The USB accessory is no longer connected.")
            return
        }
        let configuration = VZUSBPassthroughDeviceConfiguration(device: accessory)
        do {
            let device = try VZUSBPassthroughDevice(configuration: configuration)
            controller.attach(device: device) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.publish(message: "Could not attach USB device: \(error.localizedDescription)")
                } else {
                    self.attachedDevices[registryID] = device
                    self.publish()
                }
            }
        } catch {
            publish(message: "Could not prepare USB device: \(error.localizedDescription)")
        }
    }

    func usbController(_ usbController: VZUSBController, usbPassthroughDeviceDidDisconnect device: VZUSBPassthroughDevice) {
        if let entry = attachedDevices.first(where: { $0.value === device }) {
            attachedDevices.removeValue(forKey: entry.key)
        }
        publish(message: "A USB accessory was disconnected from the host.")
    }

    private func publish(message: String? = nil) {
        let items = accessories.values.map { accessory in
            let descriptor = Self.descriptor(for: accessory)
            return VMRuntimeState.USBAccessoryItem(
                id: accessory.registryID,
                name: descriptor.name,
                detail: descriptor.detail,
                isAttached: attachedDevices[accessory.registryID] != nil
            )
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        updateHandler(items, message)
    }

    private static func descriptor(for accessory: AAUSBAccessory) -> (name: String, detail: String) {
        guard let descriptor = VMUSBDeviceDescriptor(data: accessory.deviceDescriptorData) else {
            return ("USB Accessory", "Registry \(accessory.registryID)")
        }
        return (descriptor.name, descriptor.identifier)
    }
}

extension VMOSInternalVirtualMachineViewController: VZVirtualMachineDelegate {
    
    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        stopUSBAccessoryDiscovery()
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
