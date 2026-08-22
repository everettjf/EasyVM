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
    private var screenshotCaptureInProgress = false
    private var guestAgentClient: VMGuestAgentHostClient?
    private var runLease: VMRunLease?
    private var releaseSmokeTimer: Timer?
    private var releaseSmokeStage = 0
    private var releaseSmokeDeadline: Date?
    private var releaseSmokePayload: Data?
    private var releaseSmokeUploadURL: URL?
    private var releaseSmokeDownloadURL: URL?
    private var releaseSmokeGuestPath: String?
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

        guard let resourceAssessment = VMRunningRegistry.shared.configureResources(
            lease, cpuCount: model.config.cpu.count, memoryBytes: model.config.memory.size
        ) else {
            fail("Could not reserve host resources for this virtual machine.")
            return
        }
        guard resourceAssessment.allowed else {
            fail(resourceAssessment.denialReason ?? "Host resource policy rejected this virtual machine.")
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
        // A headless runtime has no window hierarchy. Binding its machine to an
        // unattached VZVirtualMachineView makes automatic display negotiation
        // stall VM startup on recent macOS releases.
        if HeadlessLaunchConfiguration.current == nil {
            virtualMachineView.virtualMachine = virtualMachine
        }


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
            if smokeTest.requireGuestAgent || smokeTest.requireKVM {
                startGuestAgent(model: model, releaseSmoke: smokeTest)
                startReleaseGuestAgentSmokeTest(smokeTest)
            } else {
                finishReleaseSmokeTest(smokeTest)
            }
            return
        }
        // Headless CLI processes must not initialize UI-only services or make
        // an interactive Keychain query. Blocking here would prevent the
        // runtime-state timer from ever publishing the already-running VM.
        if HeadlessLaunchConfiguration.current == nil {
            startScreenshotTimer()
            updateBalloonMemoryState()
            startGuestAgent(model: model)
        }
    }

    private func startReleaseGuestAgentSmokeTest(_ configuration: VMReleaseSmokeTestConfiguration) {
        let token = UUID().uuidString
        let uploadURL = FileManager.default.temporaryDirectory.appendingPathComponent("easyvm-agent-upload-\(token)")
        let downloadURL = FileManager.default.temporaryDirectory.appendingPathComponent("easyvm-agent-download-\(token)")
        let payload = Data("EasyVM real guest-agent integration \(token)\n".utf8)
        do {
            try payload.write(to: uploadURL, options: .atomic)
        } catch {
            failReleaseSmokeTest("could not create host transfer fixture: \(error.localizedDescription)", configuration)
            return
        }
        releaseSmokePayload = payload
        releaseSmokeUploadURL = uploadURL
        releaseSmokeDownloadURL = downloadURL
        releaseSmokeGuestPath = "/tmp/easyvm-agent-integration-\(token)"
        releaseSmokeDeadline = Date().addingTimeInterval(75)
        releaseSmokeStage = 0
        releaseSmokeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.advanceReleaseGuestAgentSmokeTest(configuration)
        }
    }

    private func advanceReleaseGuestAgentSmokeTest(_ configuration: VMReleaseSmokeTestConfiguration) {
        guard let runtimeState, let deadline = releaseSmokeDeadline, Date() < deadline else {
            let connection = runtimeState.map { releaseSmokeConnectionDescription($0.guestAgentState) } ?? "runtime state unavailable"
            let transfer = runtimeState.map { releaseSmokeTransferDescription($0.guestAgentTransferState) } ?? "runtime state unavailable"
            failReleaseSmokeTest(
                "timed out waiting for the Guest Agent integration test (stage \(releaseSmokeStage), connection: \(connection), transfer: \(transfer))",
                configuration
            )
            return
        }
        if releaseSmokeStage > 0, case .disconnected(let reason) = runtimeState.guestAgentState {
            failReleaseSmokeTest("Guest Agent disconnected: \(reason)", configuration)
            return
        }
        if case .failed(let reason) = runtimeState.guestAgentTransferState {
            failReleaseSmokeTest(reason, configuration)
            return
        }
        switch releaseSmokeStage {
        case 0:
            guard case .ready(let status) = runtimeState.guestAgentState else { return }
            guard status.supportsFileTransfer else {
                failReleaseSmokeTest("Guest Agent does not advertise file-transfer-v1", configuration)
                return
            }
            if configuration.requireKVM {
                guard status.supportsKVMDiagnostics, status.kvmAvailable == true, status.kvmAPIVersion == 12 else {
                    failReleaseSmokeTest("guest KVM check failed: \(status.kvmError ?? "KVM API unavailable")", configuration)
                    return
                }
            }
            guard let uploadURL = releaseSmokeUploadURL, let guestPath = releaseSmokeGuestPath else { return }
            releaseSmokeStage = 1
            guestAgentClient?.upload(localURL: uploadURL, destinationPath: guestPath, overwrite: false)
        case 1:
            guard case .completed = runtimeState.guestAgentTransferState,
                  let guestPath = releaseSmokeGuestPath, let downloadURL = releaseSmokeDownloadURL else { return }
            runtimeState.updateGuestAgentTransfer(.idle)
            releaseSmokeStage = 2
            guestAgentClient?.download(sourcePath: guestPath, destinationURL: downloadURL)
        case 2:
            guard case .completed = runtimeState.guestAgentTransferState,
                  let expected = releaseSmokePayload, let downloadURL = releaseSmokeDownloadURL else { return }
            guard (try? Data(contentsOf: downloadURL)) == expected else {
                failReleaseSmokeTest("Guest Agent download did not match the uploaded bytes", configuration)
                return
            }
            cleanupReleaseSmokeFiles()
            finishReleaseSmokeTest(configuration)
        default: return
        }
    }

    private func releaseSmokeConnectionDescription(_ state: VMGuestAgentConnectionState) -> String {
        switch state {
        case .unavailable: "unavailable"
        case .notEnrolled: "not enrolled"
        case .connecting: "connecting"
        case .authenticating: "authenticating"
        case .ready: "ready"
        case .disconnected(let reason): "disconnected: \(reason)"
        }
    }

    private func releaseSmokeTransferDescription(_ state: VMGuestAgentTransferState) -> String {
        switch state {
        case .idle: "idle"
        case .preparing(let name): "preparing \(name)"
        case .transferring(let direction, let name, let completed, let total):
            "\(direction == .upload ? "uploading" : "downloading") \(name) (\(completed)/\(total))"
        case .completed(let message): "completed: \(message)"
        case .failed(let reason): "failed: \(reason)"
        case .cancelled: "cancelled"
        }
    }

    private func failReleaseSmokeTest(_ reason: String, _ configuration: VMReleaseSmokeTestConfiguration) {
        cleanupReleaseSmokeFiles()
        VMReleaseSmokeTest.report("failed: \(reason)", configuration: configuration)
        virtualMachine.stop { [weak self] _ in
            Task { @MainActor in
                self?.runtimeState?.update(.failed("Release integration test failed: \(reason)"))
                self?.releaseRunLease()
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func cleanupReleaseSmokeFiles() {
        releaseSmokeTimer?.invalidate()
        releaseSmokeTimer = nil
        for url in [releaseSmokeUploadURL, releaseSmokeDownloadURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        releaseSmokeUploadURL = nil
        releaseSmokeDownloadURL = nil
        releaseSmokePayload = nil
    }

    private func finishReleaseSmokeTest(_ configuration: VMReleaseSmokeTestConfiguration) {
        releaseSmokeTimer?.invalidate()
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
        // The VM display is often still black when start() completes, so take a
        // quick first sample and then refresh often enough for the home card to
        // feel current. Common run-loop modes keep this working while the user
        // is dragging a window or interacting with menus.
        let timer = Timer(fire: Date().addingTimeInterval(2), interval: 10, repeats: true) { [weak self] _ in
            self?.captureScreenshot()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        screenshotTimer = timer
    }

    private func startGuestAgent(model: VMModel, releaseSmoke: VMReleaseSmokeTestConfiguration? = nil) {
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
        let enrollmentResult: VMOSResult<VMGuestAgentEnrollment?, String>
        if let smoke = releaseSmoke ?? VMReleaseSmokeTest.configuration() {
            guard let enrollmentURL = smoke.guestAgentEnrollmentURL else {
                runtimeState?.updateGuestAgent(.disconnected("The release smoke enrollment file was not configured."))
                return
            }
            enrollmentResult = loadReleaseSmokeEnrollment(at: enrollmentURL, machineIdentifierData: identifier)
        } else {
            enrollmentResult = VMGuestAgentEnrollmentStore.load(machineIdentifierData: identifier)
        }
        switch enrollmentResult {
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

    private func loadReleaseSmokeEnrollment(at url: URL, machineIdentifierData: Data) -> VMOSResult<VMGuestAgentEnrollment?, String> {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return .failure("The release Guest Agent enrollment must be a regular file.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o077 == 0 else {
                return .failure("The release Guest Agent enrollment must not be accessible by group or other users (chmod 600).")
            }
            return .success(try VMGuestAgentEnrollmentStore.decodeInstallationConfiguration(
                Data(contentsOf: url), machineIdentifierData: machineIdentifierData
            ))
        } catch {
            return .failure("The release Guest Agent enrollment is invalid: \(error.localizedDescription)")
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
        guard synchronously || !screenshotCaptureInProgress else { return }
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
            screenshotCaptureInProgress = true
            Task.detached(priority: .utility) {
                do {
                    try pngData.write(to: destination, options: .atomic)
                    await MainActor.run {
                        self.screenshotCaptureInProgress = false
                        NotificationCenter.default.post(name: AppConfigManager.newVMChangedNotification, object: nil)
                    }
                } catch {
                    EasyVMLog.error("Failed to save VM thumbnail: \(error.localizedDescription)", logger: EasyVMLog.storage)
                    await MainActor.run {
                        self.screenshotCaptureInProgress = false
                    }
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
