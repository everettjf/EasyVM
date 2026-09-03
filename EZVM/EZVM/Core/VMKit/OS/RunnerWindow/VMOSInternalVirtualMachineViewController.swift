//
//  VMOSInternalViewController.swift
//  EZVM
//
//  Created by everettjf on 2022/10/3.
//

import Cocoa
import AccessoryAccess
import Foundation
import IOKit
import ScreenCaptureKit
import Virtualization


#if arch(arm64)

public class VMOSInternalVirtualMachineViewController: NSViewController {
    // parameters
    var rootPath: URL? = nil
    var recoveryMode: Bool = false
    weak var runtimeState: VMRuntimeState?
    
    // internal
    private var graphicsBackend: (any VMGraphicsBackend)?
    private var virtualMachine: VZVirtualMachine!
    private var virtualMachineConfiguration: VZVirtualMachineConfiguration?
    private var configuredMemorySize: UInt64 = 0
    private var lifecycleGeneration = 0
    private var attemptedEFIBootRecovery = false
    private var screenshotTimer: Timer?
    private var screenshotCaptureInProgress = false
    private var guestAgentClient: VMGuestAgentHostClient?
    private var usbAccessoryCoordinator: VMUSBAccessoryCoordinator?
    private var runLease: VMRunLease?
    private var releaseSmokeTimer: Timer?
    private var releaseSmokeStage = 0
    private var releaseSmokeDeadline: Date?
    private var releaseSmokePayload: Data?
    private var releaseSmokeUploadURL: URL?
    private var releaseSmokeDownloadURL: URL?
    private var releaseSmokeGuestPath: String?
    private var releaseSmokeInputVerificationStarted = false
    private var releaseSmokeInputVerified = false
    private var releaseSmokeVisibleInputInjected = false
    private var releaseSmokeVisibleInputHoldUntil: Date?
    private var shutdownFallbackGeneration = 0
    private var networkRuntimeTracker = VMNetworkRuntimeTracker(deviceCount: 0)
    private var networkReconnectTokens: [Int: UUID] = [:]
    private var displayRefreshObservers: [NSObjectProtocol] = []
    private var pendingDisplayRefresh: DispatchWorkItem?
    // Keep the controller alive while a window-close save is still running.
    private var shutdownRetainer: VMOSInternalVirtualMachineViewController?
    

    public override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        // Do view setup here.
        
        DispatchQueue.main.async {
            self.startMachine()
        }
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.backgroundColor = .black
        installDisplayRefreshObserversIfNeeded()
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        removeDisplayRefreshObservers()
    }

    deinit {
        removeDisplayRefreshObservers()
    }

    private func installDisplayRefreshObserversIfNeeded() {
        guard displayRefreshObservers.isEmpty, let window = view.window else { return }
        let names = [
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didEndLiveResizeNotification,
        ]
        for name in names {
            displayRefreshObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.refreshAutomaticDisplayConfiguration()
            })
        }
        displayRefreshObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleDisplayRefreshAfterResize()
        })
    }

    private func removeDisplayRefreshObservers() {
        displayRefreshObservers.forEach(NotificationCenter.default.removeObserver)
        displayRefreshObservers.removeAll()
        pendingDisplayRefresh?.cancel()
        pendingDisplayRefresh = nil
    }

    private func scheduleDisplayRefreshAfterResize() {
        pendingDisplayRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshAutomaticDisplayConfiguration()
        }
        pendingDisplayRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func refreshAutomaticDisplayConfiguration() {
        // Window geometry and the Linux display stack settle independently.
        // Refresh immediately, then repeat after short delays so startup and
        // full-screen transitions cannot leave the guest on the fallback mode.
        for delay in [0.0, 0.35, 1.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.view.window != nil else { return }
                self.view.layoutSubtreeIfNeeded()
                self.graphicsBackend?.refreshDisplayConfiguration()
            }
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
        let machineIdentifierData = try? Data(contentsOf: model.machineIdentifierURL)
        let hasInstallationMedia = model.config.storageDevices.contains { $0.type == .USB }
        let guestInputReady = machineIdentifierData.map {
            VMGuestAgentEnrollmentStore.isInputReady(machineIdentifierData: $0)
        } ?? false
        let releaseSmokeRequiresVirGL = VMReleaseSmokeTest.configuration(for: rootPath)?.requireVirGL == true
        let graphicsCreation = VMGraphicsBackendFactory.make(
            forLinux: model.config.type == .linux,
            devices: model.config.graphicsDevices,
            hasInstallationMedia: hasInstallationMedia,
            guestInputReady: guestInputReady || releaseSmokeRequiresVirGL
        )
        let graphicsBackend = graphicsCreation.backend
        self.graphicsBackend = graphicsBackend
        runtimeState?.updateGraphicsBackend(
            kind: graphicsBackend.kind,
            detail: graphicsCreation.detail,
            supportsMachineSaveRestore: graphicsBackend.supportsMachineSaveRestore
        )
        let graphicsKind = graphicsBackend.kind
        let graphicsSupportsSaveRestore = graphicsBackend.supportsMachineSaveRestore
        let initialGraphicsDetail = graphicsCreation.detail
        graphicsBackend.setRuntimeIssueHandler { [weak runtimeState] issue in
            runtimeState?.updateGraphicsBackend(
                kind: graphicsKind,
                detail: issue ?? initialGraphicsDetail,
                supportsMachineSaveRestore: graphicsSupportsSaveRestore
            )
        }
        // Keep the VZ native input fallback until the authenticated guest
        // explicitly advertises uinput. The agent callback switches Custom
        // VirGL to its reliable desktop input path once it is ready.
        graphicsBackend.setGuestInputHandler(nil)
        installDisplayView(graphicsBackend.displayView)
        
        let virtualMachineConfigurationResult = runner.createConfiguration(
            model: model,
            graphicsBackend: graphicsBackend
        )
        if case let .failure(error) = virtualMachineConfigurationResult {
            fail("Could not create the virtual machine configuration: \(error)")
            return
        }
        guard case let .success(virtualMachineConfiguration) = virtualMachineConfigurationResult else {
            fail("Could not create the virtual machine configuration.")
            return
        }
        
        configuredMemorySize = virtualMachineConfiguration.memorySize
        self.virtualMachineConfiguration = virtualMachineConfiguration
        updateMachineStateSupport(for: virtualMachineConfiguration)
        installVirtualMachine(configuration: virtualMachineConfiguration)
        VMSavedStateStore.recoverInterruptedTransaction(stateURL: model.savedMachineStateURL)
        startConfiguredMachine(rootPath: rootPath, model: model)
    }

    private func installDisplayView(_ displayView: NSView) {
        view.subviews.forEach { $0.removeFromSuperview() }
        displayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(displayView)
        NSLayoutConstraint.activate([
            displayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            displayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            displayView.topAnchor.constraint(equalTo: view.topAnchor),
            displayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        DispatchQueue.main.async { [weak self] in
            self?.focusVirtualMachineDisplay()
        }
    }

    func focusVirtualMachineDisplay() {
        guard let displayView = graphicsBackend?.displayView else { return }
        let focused = view.window?.makeFirstResponder(displayView) ?? false
        EZVMLog.info("VM display first responder accepted=\(focused)")
    }

    func updateRuntimeSharedFolders(_ devices: [VMModelFieldDirectorySharingDevice]) -> String? {
        guard let configuration = virtualMachineConfiguration,
              let virtualMachine else {
            return "The virtual machine is not ready to update shared folders."
        }
        let tag = configuration.platform is VZMacPlatformConfiguration
            ? VMModelFieldDirectorySharingDevice.autoMoundTag
            : VMModelFieldDirectorySharingDevice.runtimeLinuxTag
        guard let device = virtualMachine.directorySharingDevices
            .compactMap({ $0 as? VZVirtioFileSystemDevice })
            .first(where: { $0.tag == tag }) else {
            return "The running virtual machine does not expose the EZVM shared-folder device."
        }
        device.share = VMModelFieldDirectorySharingDevice.runtimeShare(devices)
        return nil
    }

    private func installVirtualMachine(configuration: VZVirtualMachineConfiguration) {
        virtualMachine?.delegate = nil
        graphicsBackend?.bind(virtualMachine: nil)
        virtualMachine = VZVirtualMachine(configuration: configuration)
        networkReconnectTokens.removeAll()
        networkRuntimeTracker = VMNetworkRuntimeTracker(deviceCount: configuration.networkDevices.count)
        runtimeState?.updateNetworkRuntime(networkRuntimeTracker.state)
        // This controller owns the complete runtime lifecycle. Routing delegate
        // callbacks elsewhere would clear the registry without transitioning
        // the scene to `.stopped`, leaving an unusable stopped window alive.
        virtualMachine.delegate = self
        // A headless runtime has no window hierarchy. Binding its machine to an
        // unattached VZVirtualMachineView makes automatic display negotiation
        // stall VM startup on recent macOS releases.
        if HeadlessLaunchConfiguration.current?.showsWindow != false {
            graphicsBackend?.bind(virtualMachine: virtualMachine)
        }
    }

    private func updateMachineStateSupport(for configuration: VZVirtualMachineConfiguration) {
        do {
            try configuration.validateSaveRestoreSupport()
            runtimeState?.updateMachineStateConfigurationFailure(nil)
        } catch {
            runtimeState?.updateMachineStateConfigurationFailure(error.localizedDescription)
            EZVMLog.info("Machine-state save and restore is unavailable: \(error.localizedDescription)")
        }
    }

    private func rebuildVirtualMachine() -> Bool {
        guard let configuration = virtualMachineConfiguration else { return false }
        stopGuestAgent()
        installVirtualMachine(configuration: configuration)
        return true
    }

    private func retryWithColdBoot(rootPath: URL, model: VMModel, reason: String) {
        try? FileManager.default.removeItem(at: model.savedMachineStateURL)
        VMSavedStateStore.discardPending(stateURL: model.savedMachineStateURL)
        guard rebuildVirtualMachine() else {
            fail("Could not rebuild the virtual machine after \(reason).")
            return
        }
        runtimeState?.update(.starting)
        startNormally(rootPath: rootPath, model: model)
    }

    private func recoverInvalidEFIBootIfPossible(error: Error, rootPath: URL, model: VMModel) -> Bool {
        guard model.config.type == .linux,
              !attemptedEFIBootRecovery,
              VMEFIVariableStoreRecovery.isInvalidBootLoaderError(error.localizedDescription) else { return false }
        attemptedEFIBootRecovery = true
        do {
            let backup = try VMEFIVariableStoreRecovery.replaceRejectedStore(at: model.efiVariableStoreURL)
            EZVMLog.info("Rejected EFI variable store was replaced; backup: \(backup?.path ?? "none")")
            let runner = VMOSRunnerFactory.getRunner(model.config.type)
            guard case let .success(configuration) = runner.createConfiguration(
                model: model,
                graphicsBackend: graphicsBackend
            ) else {
                fail("Could not rebuild the virtual machine after repairing its EFI variable store.")
                return true
            }
            virtualMachineConfiguration = configuration
            updateMachineStateSupport(for: configuration)
            installVirtualMachine(configuration: configuration)
            runtimeState?.update(.starting)
            startNormally(rootPath: rootPath, model: model)
        } catch {
            fail("The EFI variable store is damaged and could not be repaired: \(error.localizedDescription)")
        }
        return true
    }

    private func startConfiguredMachine(rootPath: URL, model: VMModel) {
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
                    self.markNetworkRuntimeStarted()
                    self.markMachineRunning()
                    self.startScreenshotTimer()
                }
            }
        } else {
            if graphicsBackend?.supportsMachineSaveRestore == false,
               FileManager.default.fileExists(atPath: model.savedMachineStateURL.path(percentEncoded: false)) {
                // A state produced by another graphics backend cannot restore
                // into Custom VirGL safely. Cold boot and remove it so later
                // launches don't repeatedly attempt an incompatible restore.
                try? FileManager.default.removeItem(at: model.savedMachineStateURL)
                VMSavedStateStore.discardPending(stateURL: model.savedMachineStateURL)
                EZVMLog.info("Discarded saved state because Custom VirGL does not support machine-state restore.")
            } else if #available(macOS 14.0, *), FileManager.default.fileExists(atPath: model.savedMachineStateURL.path(percentEncoded: false)) {
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
                Task { @MainActor in
                    self.retryWithColdBoot(rootPath: rootPath, model: model, reason: "saved-state restore failed")
                }
                EZVMLog.error("Saved state restore failed; falling back to normal boot: \(error.localizedDescription)")
                return
            }
            self.virtualMachine.resume { result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        try? FileManager.default.removeItem(at: stateURL)
                        self.runtimeState?.update(.running)
                        self.markNetworkRuntimeStarted()
                        self.markMachineRunning()
                        self.startScreenshotTimer()
                        self.startGuestAgent(model: model)
                    case .failure(let error):
                        EZVMLog.error("Saved state resume failed; falling back to normal boot: \(error.localizedDescription)")
                        self.retryWithColdBoot(rootPath: rootPath, model: model, reason: "saved-state resume failed")
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
                runtimeState?.updateMacGuestProvisioning(.failed(error))
                fail(error)
                return
            case .success(let credential?):
                if !VMGuestProvisioningCredentialPolicy.shouldSubmitProvisioning(for: credential.attemptState) {
                    runtimeState?.updateMacGuestProvisioning(
                        credential.attemptState == .applying
                            ? .needsVerification(username: credential.username)
                            : .awaitingConfirmation(username: credential.username)
                    )
                    break
                }
                do {
                    let applyingCredential = credential.withAttemptState(.applying)
                    if case let .failure(error) = VMGuestProvisioningCredentialStore.save(
                        applyingCredential,
                        vmRootPath: rootPath
                    ) {
                        runtimeState?.updateMacGuestProvisioning(.failed(error))
                        fail(error)
                        return
                    }
                    runtimeState?.updateMacGuestProvisioning(.applying(username: credential.username))
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
                                let retryResult = VMGuestProvisioningCredentialStore.save(
                                    credential.withAttemptState(.prepared),
                                    vmRootPath: rootPath
                                )
                                let retryWasPrepared: Bool
                                switch retryResult {
                                case .success:
                                    retryWasPrepared = true
                                case .failure(let keychainError):
                                    retryWasPrepared = false
                                    EZVMLog.error(keychainError, logger: EZVMLog.lifecycle)
                                }
                                let frameworkError = error as NSError
                                EZVMLog.error(
                                    "Guest provisioning VM start failed: \(frameworkError.domain) (\(frameworkError.code)); safe retry prepared: \(retryWasPrepared).",
                                    logger: EZVMLog.lifecycle
                                )
                                let guidance = VMGuestProvisioningStartFailureGuidance.message(
                                    retryWasPrepared: retryWasPrepared
                                )
                                self.runtimeState?.updateMacGuestProvisioning(.failed(guidance))
                                if !self.recoverInvalidEFIBootIfPossible(error: error, rootPath: rootPath, model: model) {
                                    self.fail(guidance)
                                }
                            } else {
                                // Starting the VM only proves that the options were accepted.
                                // Virtualization.framework does not publish a callback that
                                // confirms the guest account has been created, so retain the
                                // retry credential until the user verifies setup in the guest.
                                let awaitingCredential = credential.withAttemptState(.awaitingConfirmation)
                                if case let .failure(error) = VMGuestProvisioningCredentialStore.save(
                                    awaitingCredential,
                                    vmRootPath: rootPath
                                ) {
                                    EZVMLog.error(error, logger: EZVMLog.lifecycle)
                                }
                                self.runtimeState?.updateMacGuestProvisioning(.awaitingConfirmation(username: credential.username))
                                self.didStart(rootPath: rootPath, model: model)
                            }
                        }
                    }
                    return
                } catch {
                    _ = VMGuestProvisioningCredentialStore.save(
                        credential.withAttemptState(.prepared),
                        vmRootPath: rootPath
                    )
                    let error = error as NSError
                    EZVMLog.error(
                        "Guest provisioning validation failed before VM start: \(error.domain) (\(error.code)).",
                        logger: EZVMLog.lifecycle
                    )
                    let guidance = VMGuestProvisioningValidationGuidance.message(for: error)
                    runtimeState?.updateMacGuestProvisioning(.failed(guidance))
                    fail(guidance)
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
                    if !self.recoverInvalidEFIBootIfPossible(error: error, rootPath: rootPath, model: model) {
                        self.fail("Could not start the virtual machine: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func confirmMacGuestProvisioningCompleted() {
        guard VMGuestProvisioningCredentialPolicy.shouldDeleteCredential(
            after: .userConfirmedSetupCompleted
        ), let rootPath else { return }

        switch VMGuestProvisioningCredentialStore.delete(vmRootPath: rootPath) {
        case .success:
            runtimeState?.updateMacGuestProvisioning(.completed)
            EZVMLog.info(
                "Removed the temporary macOS guest provisioning credential after user confirmation.",
                logger: EZVMLog.lifecycle
            )
        case .failure(let error):
            runtimeState?.updateMacGuestProvisioning(.failed(error))
            EZVMLog.error(error, logger: EZVMLog.lifecycle)
        }
    }

    func retryMacGuestProvisioningOnNextStart() {
        guard let rootPath else { return }
        switch VMGuestProvisioningCredentialStore.load(vmRootPath: rootPath) {
        case .success(let credential?):
            switch VMGuestProvisioningCredentialStore.save(
                credential.withAttemptState(.prepared),
                vmRootPath: rootPath
            ) {
            case .success:
                runtimeState?.updateMacGuestProvisioning(.retryPrepared(username: credential.username))
            case .failure(let error):
                runtimeState?.updateMacGuestProvisioning(.failed(error))
            }
        case .success(nil):
            runtimeState?.updateMacGuestProvisioning(.failed("The temporary provisioning credential is no longer available."))
        case .failure(let error):
            runtimeState?.updateMacGuestProvisioning(.failed(error))
        }
    }

    private func didStart(rootPath: URL, model: VMModel) {
        runtimeState?.update(.running)
        markNetworkRuntimeStarted()
        markMachineRunning()
        // Custom VirGL starts with the persisted fallback mode (normally
        // 1280x720). Negotiate once the VM and window are both live so Linux
        // sees the actual drawable size without requiring a manual resize or
        // a full-screen round trip first.
        refreshAutomaticDisplayConfiguration()
        if let smokeTest = VMReleaseSmokeTest.configuration(for: rootPath) {
            if let unmetRequirement = unmetReleaseSmokeRequirement(smokeTest, model: model) {
                fail(unmetRequirement)
                return
            }
            if smokeTest.requireGuestAgent || smokeTest.requireGuestInput || smokeTest.requireAbsoluteGuestPointer || smokeTest.requireKVM {
                startGuestAgent(model: model, releaseSmoke: smokeTest)
                startReleaseGuestAgentSmokeTest(smokeTest)
            } else {
                finishReleaseSmokeTest(smokeTest)
            }
            return
        }
        // A truly headless CLI process must not initialize UI-only services.
        // A launch that explicitly shows
        // a VM window is interactive, though, and needs the guest agent for
        // keyboard and pointer delivery with Custom VirGL.
        if HeadlessLaunchConfiguration.current?.showsWindow != false {
            startScreenshotTimer()
            updateBalloonMemoryState()
            startGuestAgent(model: model)
        }
    }

    private func unmetReleaseSmokeRequirement(
        _ smoke: VMReleaseSmokeTestConfiguration,
        model: VMModel
    ) -> String? {
        if smoke.requireVirGL, graphicsBackend?.kind != .customVirGL {
            return "Release test requires Custom VirGL, but the active backend is \(graphicsBackend?.kind.rawValue ?? "unknown")."
        }
        if smoke.requireMemoryBalloon, virtualMachineConfiguration?.memoryBalloonDevices.isEmpty != false {
            return "Release test requires a Virtio memory balloon device."
        }
        if smoke.requireEntropy, virtualMachineConfiguration?.entropyDevices.isEmpty != false {
            return "Release test requires a Virtio entropy device."
        }
        if smoke.requireVirtioSocket, virtualMachineConfiguration?.socketDevices.isEmpty != false {
            return "Release test requires a Virtio socket device."
        }
        if smoke.requireASIFStorage,
           !model.config.storageDevices.contains(where: { $0.type == .Block && $0.format == .asif }) {
            return "Release test requires an ASIF block-storage device."
        }
        if smoke.requireVMNet,
           virtualMachineConfiguration?.networkDevices.contains(where: {
               $0.attachment is VZVmnetNetworkDeviceAttachment
           }) != true {
            return "Release test requires a VMNet network attachment."
        }
        if smoke.requireMachineStateSupport,
           let reason = runtimeState?.machineStateUnavailabilityReason {
            return "Release test requires machine-state save and restore support: \(reason)"
        }
        return nil
    }

    private func startReleaseGuestAgentSmokeTest(_ configuration: VMReleaseSmokeTestConfiguration) {
        let token = UUID().uuidString
        let uploadURL = FileManager.default.temporaryDirectory.appendingPathComponent("ezvm-agent-upload-\(token)")
        let downloadURL = FileManager.default.temporaryDirectory.appendingPathComponent("ezvm-agent-download-\(token)")
        let payload = Data("EZVM real guest-agent integration \(token)\n".utf8)
        do {
            try payload.write(to: uploadURL, options: .atomic)
        } catch {
            failReleaseSmokeTest("could not create host transfer fixture: \(error.localizedDescription)", configuration)
            return
        }
        releaseSmokePayload = payload
        releaseSmokeUploadURL = uploadURL
        releaseSmokeDownloadURL = downloadURL
        releaseSmokeGuestPath = "/tmp/ezvm-agent-integration-\(token)"
        releaseSmokeDeadline = Date().addingTimeInterval(75)
        releaseSmokeStage = 0
        releaseSmokeInputVerificationStarted = false
        releaseSmokeInputVerified = false
        releaseSmokeVisibleInputInjected = false
        releaseSmokeVisibleInputHoldUntil = nil
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
            if configuration.requireGuestInput, !status.supportsGuestInput {
                failReleaseSmokeTest("Guest Agent does not advertise input-uinput-v1", configuration)
                return
            }
            if configuration.requireAbsoluteGuestPointer, !status.supportsAbsoluteGuestPointer {
                failReleaseSmokeTest("Guest Agent does not advertise input-uinput-absolute-v1", configuration)
                return
            }
            if configuration.requireGuestInput, !releaseSmokeInputVerified {
                guard !releaseSmokeInputVerificationStarted else { return }
                releaseSmokeInputVerificationStarted = true
                Task { [weak self] in
                    guard let self, let guestAgentClient = self.guestAgentClient else { return }
                    do {
                        try await guestAgentClient.verifyInputInjection()
                        self.releaseSmokeInputVerified = true
                    } catch {
                        self.failReleaseSmokeTest(
                            "Guest Agent could not inject a no-op uinput event: \(error.localizedDescription)",
                            configuration
                        )
                    }
                }
                return
            }
            if configuration.injectVisibleGuestInput, !releaseSmokeVisibleInputInjected {
                releaseSmokeVisibleInputInjected = true
                releaseSmokeVisibleInputHoldUntil = Date().addingTimeInterval(60)
                Task { [weak self] in
                    guard let self, let guestAgentClient = self.guestAgentClient else { return }
                    do {
                        try await guestAgentClient.injectVisibleInputFixture()
                    } catch {
                        self.failReleaseSmokeTest(
                            "Guest Agent could not inject the visible keyboard fixture: \(error.localizedDescription)",
                            configuration
                        )
                    }
                }
                return
            }
            if let holdUntil = releaseSmokeVisibleInputHoldUntil, Date() < holdUntil {
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
        releaseSmokeInputVerificationStarted = false
        releaseSmokeInputVerified = false
        releaseSmokeVisibleInputInjected = false
        releaseSmokeVisibleInputHoldUntil = nil
    }

    private func finishReleaseSmokeTest(_ configuration: VMReleaseSmokeTestConfiguration) {
        releaseSmokeTimer?.invalidate()
        if configuration.saveMachineState {
            startReleaseMachineStateSave(configuration)
            return
        }
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

    private func startReleaseMachineStateSave(_ configuration: VMReleaseSmokeTestConfiguration) {
        guard runtimeState?.canSave == true, let rootPath else {
            failReleaseSmokeTest(
                "machine state is unavailable: \(runtimeState?.machineStateUnavailabilityReason ?? "unknown reason")",
                configuration
            )
            return
        }
        releaseSmokeDeadline = Date().addingTimeInterval(30)
        releaseSmokeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self, let runtimeState = self.runtimeState else { return }
            if runtimeState.phase == .stopped {
                timer.invalidate()
                let stateURL = rootPath.appending(path: "MachineState.vzvmsave")
                guard FileManager.default.fileExists(atPath: stateURL.path) else {
                    VMReleaseSmokeTest.report("failed: save completed without a machine-state file", configuration: configuration)
                    NSApplication.shared.terminate(nil)
                    return
                }
                VMReleaseSmokeTest.report("machine-state-saved", configuration: configuration)
                NSApplication.shared.terminate(nil)
            } else if case let .failed(message) = runtimeState.phase {
                timer.invalidate()
                VMReleaseSmokeTest.report("failed: \(message)", configuration: configuration)
                NSApplication.shared.terminate(nil)
            } else if Date() >= (self.releaseSmokeDeadline ?? .distantPast) {
                timer.invalidate()
                VMReleaseSmokeTest.report("failed: timed out saving machine state", configuration: configuration)
                self.forceStopMachine()
                NSApplication.shared.terminate(nil)
            }
        }
        saveAndStopMachine()
    }

    func pauseMachine() {
        guard virtualMachine?.canPause == true else { return }
        runtimeState?.update(.pausing)
        virtualMachine.pause { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.guestAgentClient?.virtualMachineDidPause()
                    self.runtimeState?.update(.paused)
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
                case .success:
                    self.runtimeState?.update(.running)
                    self.guestAgentClient?.virtualMachineDidResume()
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

    func reconnectNetworkDevice(deviceIndex: Int) {
        guard virtualMachine != nil,
              virtualMachine.state == .running || virtualMachine.state == .paused,
              virtualMachine.networkDevices.indices.contains(deviceIndex),
              virtualMachineConfiguration?.networkDevices.indices.contains(deviceIndex) == true,
              let attachment = virtualMachineConfiguration?.networkDevices[deviceIndex].attachment,
              networkRuntimeTracker.beginReconnect(deviceIndex: deviceIndex) else { return }

        let operationToken = UUID()
        networkReconnectTokens[deviceIndex] = operationToken
        let device = virtualMachine.networkDevices[deviceIndex]
        runtimeState?.updateNetworkRuntime(networkRuntimeTracker.state)
        EZVMLog.info("Reconnecting network adapter \(deviceIndex + 1).", logger: EZVMLog.network)
        device.attachment = attachment

        // VZNetworkDevice has no completion handler for attachment changes.
        // A failure is authoritative through the VM delegate; a short delayed
        // read only confirms that the requested attachment remained installed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self, weak device] in
            guard let self,
                  self.networkReconnectTokens[deviceIndex] == operationToken,
                  let device,
                  self.virtualMachine?.networkDevices.indices.contains(deviceIndex) == true,
                  self.virtualMachine.networkDevices[deviceIndex] === device else { return }
            if device.attachment != nil {
                self.networkReconnectTokens.removeValue(forKey: deviceIndex)
                self.networkRuntimeTracker.markConnected(deviceIndex: deviceIndex)
                self.runtimeState?.updateNetworkRuntime(self.networkRuntimeTracker.state)
                EZVMLog.info("Network adapter \(deviceIndex + 1) reconnected.", logger: EZVMLog.network)
            } else {
                self.networkReconnectTokens.removeValue(forKey: deviceIndex)
                self.networkRuntimeTracker.markDisconnected(
                    deviceIndex: deviceIndex,
                    reason: "The host did not accept the network attachment. Check the selected interface and try again."
                )
                self.runtimeState?.updateNetworkRuntime(self.networkRuntimeTracker.state)
                EZVMLog.error(
                    "Network adapter \(deviceIndex + 1) remained disconnected after a reconnect request.",
                    logger: EZVMLog.network
                )
            }
        }
    }

    func discoverUSBAccessories() {
        guard VMHostCapability.accessoryAccess.isGranted else {
            runtimeState?.updateUSBPassthrough(.failed("This build is missing the Accessory Access entitlement."))
            return
        }
        guard virtualMachine != nil, !virtualMachine.usbControllers.isEmpty else {
            runtimeState?.updateUSBPassthrough(.failed("The virtual machine has no USB controller."))
            return
        }
        if usbAccessoryCoordinator == nil {
            usbAccessoryCoordinator = VMUSBAccessoryCoordinator(
                virtualMachine: virtualMachine,
                update: { [weak self] state in self?.runtimeState?.updateUSBPassthrough(state) }
            )
        }
        runtimeState?.updateUSBPassthrough(.discovering)
        usbAccessoryCoordinator?.start()
    }

    func attachUSBAccessory(registryID: UInt64) {
        usbAccessoryCoordinator?.attach(registryID: registryID)
    }

    func detachUSBAccessory(registryID: UInt64) {
        usbAccessoryCoordinator?.detach(registryID: registryID)
    }

    func dismissUSBPassthroughNotice() {
        usbAccessoryCoordinator?.dismissNotice()
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
        guard virtualMachine != nil else { return }
        runtimeState?.update(.stopping)
        markMachineStopping()
        if runtimeState?.guestAgentState.isReady == true {
            // Linux desktops do not consistently implement the platform
            // shutdown request exposed by Virtualization.framework. Prefer
            // the authenticated agent when available, while retaining the
            // same bounded force-stop fallback.
            guestAgentClient?.send(.shutdown)
            scheduleShutdownFallback()
            return
        }
        guard virtualMachine.canRequestStop else {
            fail("The guest cannot accept a shutdown request while the Guest Agent is unavailable.")
            return
        }
        do {
            try virtualMachine.requestStop()
            scheduleShutdownFallback()
        } catch {
            fail("The guest did not accept the shutdown request: \(error.localizedDescription)")
        }
    }

    func forceStopMachine() {
        cancelShutdownFallback()
        lifecycleGeneration += 1
        if let rootPath {
            let stateURL = rootPath.appending(path: "MachineState.vzvmsave")
            VMSavedStateStore.discardPending(stateURL: stateURL)
            try? FileManager.default.removeItem(at: stateURL)
        }
        shutdownRetainer = nil
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
                    self.releaseVirtualMachineAfterStop()
                    self.runtimeState?.update(.stopped)
                    self.releaseRunLease()
                }
            }
        }
    }

    func saveAndStopMachine() {
        guard runtimeState?.canPersistMachineState == true else {
            // Retain the controller until the guest acknowledges shutdown and
            // the VM delegate releases the Custom Virtio renderer.
            shutdownRetainer = self
            requestStopMachine()
            return
        }
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
        lifecycleGeneration += 1
        let operationGeneration = lifecycleGeneration
        let save = { [weak self] in
            guard let self, self.lifecycleGeneration == operationGeneration else { return }
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
                    guard self.lifecycleGeneration == operationGeneration else {
                        VMSavedStateStore.discardPending(stateURL: stateURL)
                        return
                    }
                    if let error {
                        VMSavedStateStore.discardPending(stateURL: stateURL)
                        self.fail("Could not save the virtual machine state: \(error.localizedDescription)")
                    } else {
                        do {
                            try VMSavedStateStore.commit(pendingURL: pendingURL, stateURL: stateURL)
                            self.releaseVirtualMachineAfterStop()
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
                guard let self, self.lifecycleGeneration == operationGeneration else { return }
                switch result {
                case .success: save()
                case .failure(let error):
                    Task { @MainActor in
                        self.fail("Could not pause before saving: \(error.localizedDescription)")
                        self.shutdownRetainer = nil
                    }
                }
            }
        } else {
            shutdownRetainer = nil
        }
    }

    private func releaseVirtualMachineAfterStop() {
        cancelShutdownFallback()
        networkReconnectTokens.removeAll()
        networkRuntimeTracker = VMNetworkRuntimeTracker(deviceCount: 0)
        runtimeState?.updateNetworkRuntime(.unavailable)
        usbAccessoryCoordinator?.stop()
        usbAccessoryCoordinator = nil
        runtimeState?.updateUSBPassthrough(.idle)
        stopGuestAgent()
        screenshotTimer?.invalidate()
        screenshotTimer = nil
        graphicsBackend?.bind(virtualMachine: nil)
        virtualMachine?.delegate = nil
        // VZVirtualMachine retains its custom Virtio device delegate. Release
        // it before shutting down VirGL so the old VirtioGPUDevice cannot keep
        // the process-global virglrenderer instance alive across an in-app VM
        // restart (the next virgl_renderer_init would otherwise return EINVAL).
        virtualMachine = nil
        graphicsBackend?.shutdown()
        graphicsBackend = nil
    }

    private func scheduleShutdownFallback() {
        shutdownFallbackGeneration += 1
        let generation = shutdownFallbackGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self,
                  self.shutdownFallbackGeneration == generation,
                  self.runtimeState?.phase == .stopping,
                  self.virtualMachine != nil else { return }
            EZVMLog.error("Guest did not stop within 20 seconds; forcing the virtual machine to stop.")
            self.forceStopMachine()
        }
    }

    private func cancelShutdownFallback() {
        shutdownFallbackGeneration += 1
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
        releaseVirtualMachineAfterStop()
        shutdownRetainer = nil
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

    private func markNetworkRuntimeStarted() {
        networkRuntimeTracker.markStarted()
        runtimeState?.updateNetworkRuntime(networkRuntimeTracker.state)
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
        guard UserDefaults.standard.bool(forKey: VMThumbnailPreferences.screenCaptureEnabledKey) else {
            screenshotTimer = nil
            return
        }
        guard !hasMeaningfulThumbnail() else {
            screenshotTimer = nil
            return
        }
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
            graphicsBackend?.setDynamicDisplayReady(true)
            return
        }
        guard let device = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
            runtimeState?.updateGuestAgent(.unavailable)
            graphicsBackend?.setDynamicDisplayReady(true)
            return
        }
        guard let identifier = try? Data(contentsOf: model.machineIdentifierURL) else {
            runtimeState?.updateGuestAgent(.disconnected("The VM machine identifier is unreadable."))
            graphicsBackend?.setDynamicDisplayReady(true)
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
            graphicsBackend?.setDynamicDisplayReady(true)
        case .success(nil):
            runtimeState?.updateGuestAgent(.notEnrolled)
            graphicsBackend?.setDynamicDisplayReady(true)
        case .success(let enrollment?):
            guard let runtimeState else { return }
            let client = VMGuestAgentHostClient(
                device: device,
                enrollment: enrollment,
                runtimeState: runtimeState
            ) { [weak self] guestKeyboardEnabled, absolutePointerEnabled in
                guard let self else { return }
                if guestKeyboardEnabled {
                    self.graphicsBackend?.setGuestInputHandler { [weak self] events in
                        self?.guestAgentClient?.sendInputEvents(events)
                    }
                } else {
                    self.graphicsBackend?.setGuestInputHandler(nil)
                }
                self.graphicsBackend?.setAbsolutePointerEnabled(absolutePointerEnabled)
            } onDesktopSessionChanged: { [weak self] active in
                self?.graphicsBackend?.setDynamicDisplayReady(active)
            } onStatusReady: { status in
                guard status.supportsDesktopGuestInput else { return }
                VMGuestAgentEnrollmentStore.markInputReady(machineIdentifierData: identifier)
            }
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

    func useCurrentDisplayAsThumbnail() {
        captureScreenshot(synchronously: true, allowReplacement: true)
    }

    private func captureScreenshot(synchronously: Bool = false, allowReplacement: Bool = false) {
        guard UserDefaults.standard.bool(forKey: VMThumbnailPreferences.screenCaptureEnabledKey) else { return }
        guard synchronously || !screenshotCaptureInProgress else { return }
        guard allowReplacement || !hasMeaningfulThumbnail() else { return }
        guard let rootPath, let view = graphicsBackend?.displayView, let window = view.window else { return }
        let viewRect = view.convert(view.bounds, to: nil)
        guard viewRect.width > 1, viewRect.height > 1 else { return }

        screenshotCaptureInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let capturedWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                    screenshotCaptureInProgress = false
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: capturedWindow)
                let configuration = SCScreenshotConfiguration()
                configuration.ignoreShadows = true
                configuration.showsCursor = false
                configuration.includeChildWindows = false
                configuration.sourceRect = CGRect(
                    x: viewRect.minX,
                    y: window.frame.height - viewRect.maxY,
                    width: viewRect.width,
                    height: viewRect.height
                )
                let scale = min(1, 720 / max(viewRect.width, 1))
                configuration.width = max(1, Int(viewRect.width * scale))
                configuration.height = max(1, Int(viewRect.height * scale))
                let output = try await SCScreenshotManager.captureScreenshot(
                    contentFilter: filter,
                    configuration: configuration
                )
                guard let image = output.sdrImage else {
                    screenshotCaptureInProgress = false
                    return
                }
                guard allowReplacement || isMeaningfulThumbnail(image) else {
                    screenshotCaptureInProgress = false
                    return
                }
                guard let pngData = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    screenshotCaptureInProgress = false
                    return
                }
                try pngData.write(to: rootPath.appending(path: "screenshot.png"), options: .atomic)
                screenshotCaptureInProgress = false
                if !allowReplacement {
                    screenshotTimer?.invalidate()
                    screenshotTimer = nil
                }
                NotificationCenter.default.post(name: AppConfigManager.newVMChangedNotification, object: nil)
            } catch {
                screenshotCaptureInProgress = false
                EZVMLog.error("Failed to capture VM thumbnail: \(error.localizedDescription)", logger: EZVMLog.storage)
            }
        }
    }

    private func hasMeaningfulThumbnail() -> Bool {
        guard let rootPath,
              let image = NSImage(contentsOf: rootPath.appending(path: "screenshot.png")),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        return isMeaningfulThumbnail(cgImage)
    }

    private func isMeaningfulThumbnail(_ image: CGImage) -> Bool {
        let sampleWidth = 32
        let sampleHeight = 32
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: sampleWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        return rendered && VMThumbnailValidator.isMeaningfulRGBA(pixels)
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
    }

}

extension VMOSInternalVirtualMachineViewController: VZVirtualMachineDelegate {
    
    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        releaseVirtualMachineAfterStop()
        shutdownRetainer = nil
        runtimeState?.update(.stopped)
        releaseRunLease()
    }
    
    
    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        
        fail("The virtual machine stopped unexpectedly: \(error.localizedDescription)")
    }
    
    public func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: Error) {
        guard let deviceIndex = virtualMachine.networkDevices.firstIndex(where: { $0 === networkDevice }) else {
            EZVMLog.error("An unknown network device disconnected: \(error.localizedDescription)", logger: EZVMLog.network)
            return
        }
        networkReconnectTokens.removeValue(forKey: deviceIndex)
        networkRuntimeTracker.markDisconnected(
            deviceIndex: deviceIndex,
            reason: VMNetworkFailureGuidance.disconnectReason(
                frameworkDescription: error.localizedDescription
            )
        )
        runtimeState?.updateNetworkRuntime(networkRuntimeTracker.state)
        EZVMLog.error(
            "Network adapter \(deviceIndex + 1) disconnected: \(error.localizedDescription)",
            logger: EZVMLog.network
        )
    }
}

@available(macOS 27.0, *)
@MainActor
private final class VMUSBAccessoryCoordinator: NSObject, AAUSBAccessoryListener, VZUSBController.Delegate {
    private weak var virtualMachine: VZVirtualMachine?
    private let update: (VMUSBPassthroughState) -> Void
    private var accessories: [UInt64: AAUSBAccessory] = [:]
    private var attachedDevices: [UInt64: VZUSBPassthroughDevice] = [:]
    private var operations: [UInt64: VMUSBDeviceOperation] = [:]
    private var operationTokens: [UInt64: UUID] = [:]
    private var notice: VMUSBPassthroughNotice?
    private var listenerLifecycle = VMUSBListenerLifecycle()

    var hasAttachedDevices: Bool { !attachedDevices.isEmpty }

    init(virtualMachine: VZVirtualMachine, update: @escaping (VMUSBPassthroughState) -> Void) {
        self.virtualMachine = virtualMachine
        self.update = update
    }

    func start() {
        guard !listenerLifecycle.isRegistered else {
            publish()
            return
        }
        let registrationToken = listenerLifecycle.beginRegistration()
        AAUSBAccessoryManager.shared.registerListener(self, matchingCriteria: []) { [weak self] accessories, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    guard self.listenerLifecycle.failRegistration(token: registrationToken) else { return }
                    let guidance = VMUSBFailureGuidance.message(
                        for: Self.failureKind(error),
                        fallback: "Accessory Access failed: \(error.localizedDescription)"
                    )
                    EZVMLog.error("Accessory Access registration failed: \(error.localizedDescription)", logger: EZVMLog.lifecycle)
                    self.update(.failed(guidance))
                    return
                }
                guard self.listenerLifecycle.completeRegistration(token: registrationToken) else {
                    AAUSBAccessoryManager.shared.unregisterListener(self) {}
                    return
                }
                for accessory in accessories {
                    self.accessories[accessory.registryID] = accessory
                }
                self.virtualMachine?.usbControllers.first?.delegate = self
                self.publish()
            }
        }
    }

    func stop() {
        virtualMachine?.usbControllers.first?.delegate = nil
        let shouldUnregister = listenerLifecycle.stop()
        if shouldUnregister {
            AAUSBAccessoryManager.shared.unregisterListener(self) {}
        }
        accessories.removeAll()
        attachedDevices.removeAll()
        operations.removeAll()
        operationTokens.removeAll()
        notice = nil
    }

    func attach(registryID: UInt64) {
        guard operations[registryID] == nil,
              attachedDevices[registryID] == nil,
              let accessory = accessories[registryID],
              let controller = virtualMachine?.usbControllers.first else { return }
        operations[registryID] = .attaching
        let operationToken = UUID()
        operationTokens[registryID] = operationToken
        notice = nil
        publish()
        do {
            let configuration = VZUSBPassthroughDeviceConfiguration(device: accessory)
            let device = try VZUSBPassthroughDevice(configuration: configuration)
            Task { @MainActor [weak self] in
                do {
                    try await controller.attach(device: device)
                    guard let self else {
                        try? await controller.detach(device: device)
                        return
                    }
                    guard self.operationTokens[registryID] == operationToken else {
                        try? await controller.detach(device: device)
                        return
                    }
                    self.operations.removeValue(forKey: registryID)
                    self.operationTokens.removeValue(forKey: registryID)
                    self.attachedDevices[registryID] = device
                    self.publish()
                } catch {
                    guard let self,
                          self.operationTokens[registryID] == operationToken else { return }
                    self.operations.removeValue(forKey: registryID)
                    self.operationTokens.removeValue(forKey: registryID)
                    self.notice = .attachFailed(
                        deviceTitle: self.title(for: registryID),
                        detail: VMUSBFailureGuidance.message(
                            for: Self.failureKind(error),
                            fallback: error.localizedDescription
                        )
                    )
                    EZVMLog.error("USB attach failed: \(error.localizedDescription)", logger: EZVMLog.lifecycle)
                    self.publish()
                }
            }
        } catch {
            operations.removeValue(forKey: registryID)
            operationTokens.removeValue(forKey: registryID)
            notice = .attachFailed(
                deviceTitle: title(for: registryID),
                detail: VMUSBFailureGuidance.message(
                    for: Self.failureKind(error),
                    fallback: error.localizedDescription
                )
            )
            EZVMLog.error("USB device creation failed: \(error.localizedDescription)", logger: EZVMLog.lifecycle)
            publish()
        }
    }

    func detach(registryID: UInt64) {
        guard operations[registryID] == nil,
              let device = attachedDevices[registryID],
              let controller = virtualMachine?.usbControllers.first else { return }
        operations[registryID] = .detaching
        let operationToken = UUID()
        operationTokens[registryID] = operationToken
        notice = nil
        publish()
        Task { @MainActor [weak self] in
            do {
                try await controller.detach(device: device)
                guard let self,
                      self.operationTokens[registryID] == operationToken else { return }
                self.operations.removeValue(forKey: registryID)
                self.operationTokens.removeValue(forKey: registryID)
                self.attachedDevices.removeValue(forKey: registryID)
                self.publish()
            } catch {
                guard let self,
                      self.operationTokens[registryID] == operationToken else { return }
                self.operations.removeValue(forKey: registryID)
                self.operationTokens.removeValue(forKey: registryID)
                let failureKind = Self.failureKind(error)
                if VMUSBFailureGuidance.confirmsDeviceIsDisconnected(failureKind) {
                    self.attachedDevices.removeValue(forKey: registryID)
                    self.notice = .unexpectedDisconnect(deviceTitle: self.title(for: registryID))
                } else {
                    self.notice = .detachFailed(
                        deviceTitle: self.title(for: registryID),
                        detail: VMUSBFailureGuidance.message(
                            for: failureKind,
                            fallback: error.localizedDescription
                        )
                    )
                }
                EZVMLog.error("USB detach failed: \(error.localizedDescription)", logger: EZVMLog.lifecycle)
                self.publish()
            }
        }
    }

    func dismissNotice() {
        notice = nil
        publish()
    }

    nonisolated func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        Task { @MainActor [weak self] in
            guard let self, self.listenerLifecycle.acceptsAccessoryCallbacks else { return }
            self.accessories[usbAccessory.registryID] = usbAccessory
            self.publish()
        }
    }

    nonisolated func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        Task { @MainActor [weak self] in
            guard let self, self.listenerLifecycle.acceptsAccessoryCallbacks else { return }
            let registryID = usbAccessory.registryID
            let deviceTitle = self.title(for: registryID)
            let wasAttached = self.attachedDevices.removeValue(forKey: registryID) != nil
            self.accessories.removeValue(forKey: registryID)
            self.operations.removeValue(forKey: registryID)
            self.operationTokens.removeValue(forKey: registryID)
            if wasAttached {
                self.notice = .unexpectedDisconnect(deviceTitle: deviceTitle)
            }
            self.publish()
        }
    }

    nonisolated func usbController(
        _ usbController: VZUSBController,
        usbPassthroughDeviceDidDisconnect device: VZUSBPassthroughDevice
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  let registryID = VMUSBControllerSupport.registryID(
                    forDisconnected: device,
                    in: self.attachedDevices
                  ) else { return }
            let wasExplicitDetach = self.operations[registryID] == .detaching
            let deviceTitle = self.title(for: registryID)
            self.attachedDevices.removeValue(forKey: registryID)
            self.operations.removeValue(forKey: registryID)
            self.operationTokens.removeValue(forKey: registryID)
            if !wasExplicitDetach {
                self.notice = .unexpectedDisconnect(deviceTitle: deviceTitle)
                EZVMLog.info(
                    "USB passthrough device disconnected unexpectedly (registry ID: \(registryID)).",
                    logger: EZVMLog.lifecycle
                )
            }
            self.publish()
        }
    }

    private func publish() {
        let devices = accessories.values.compactMap {
            self.summary(for: $0)
        }.sorted {
            ($0.title.localizedLowercase, $0.vendorID, $0.productID, $0.registryID)
                < ($1.title.localizedLowercase, $1.vendorID, $1.productID, $1.registryID)
        }
        update(.ready(VMUSBPassthroughSnapshot(
            devices: devices,
            attachedRegistryIDs: Set(attachedDevices.keys),
            operations: operations,
            notice: notice
        )))
    }

    private static func failureKind(_ error: Error) -> VMUSBFailureKind {
        let error = error as NSError
        let framework: VMUSBFailureFramework = if error.domain == AAErrorDomain {
            .accessoryAccess
        } else if error.domain == VZErrorDomain {
            .virtualization
        } else {
            .other
        }
        return VMUSBFailureGuidance.classify(framework: framework, code: error.code)
    }

    private func title(for registryID: UInt64) -> String {
        guard let accessory = accessories[registryID] else { return "USB accessory" }
        return summary(for: accessory)?.title ?? "USB accessory"
    }

    private func summary(for accessory: AAUSBAccessory) -> VMUSBDeviceDescriptorSummary? {
        let names = VMUSBRegistryMetadata.names(registryID: accessory.registryID)
        return VMUSBDeviceDescriptorSummary.parse(
            registryID: accessory.registryID,
            descriptor: accessory.deviceDescriptorData,
            manufacturerName: names.manufacturer,
            productName: names.product
        )
    }
}

private enum VMUSBRegistryMetadata {
    static func names(registryID: UInt64) -> (manufacturer: String?, product: String?) {
        guard let matching = IORegistryEntryIDMatching(registryID) else {
            return (nil, nil)
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return (nil, nil) }
        defer { IOObjectRelease(service) }

        return (
            stringProperty(service: service, keys: ["USB Vendor Name", "kUSBVendorString"]),
            stringProperty(service: service, keys: ["USB Product Name", "kUSBProductString"])
        )
    }

    private static func stringProperty(service: io_service_t, keys: [String]) -> String? {
        for key in keys {
            guard let value = IORegistryEntryCreateCFProperty(
                service,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() else { continue }
            if let string = value as? String { return string }
        }
        return nil
    }
}

#endif
