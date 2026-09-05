import AVFoundation
import UserNotifications
import EZVMCore
import SwiftUI
import UniformTypeIdentifiers
import Virtualization

private let omarchyMetadataQueue = DispatchQueue(label: "com.everettjf.ezvm.omarchy.metadata")

final class OmarchyVirtualMachineInputView: VZVirtualMachineView {
    private func recordAcceptanceRoute(_ route: String, event: NSEvent) {
        guard ProcessInfo.processInfo.environment[
            OmarchyWorkspaceConfiguration.acceptanceEnabledKey
        ] == "1", let cgEvent = event.cgEvent else { return }
        let marker = cgEvent.getIntegerValueField(.eventSourceUserData)
        guard marker == OmarchyFocusedCommandBridge.acceptanceMarker
                || marker == OmarchyFocusedCommandBridge.syntheticMarker else { return }
        NSLog(
            "Omarchy acceptance input route=%@ keyCode=%hu flags=%llu marker=%lld",
            route, event.keyCode, event.modifierFlags.rawValue, marker
        )
    }

    override func keyDown(with event: NSEvent) {
        recordAcceptanceRoute("keyDown", event: event)
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        recordAcceptanceRoute("keyUp", event: event)
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        recordAcceptanceRoute("flagsChanged", event: event)
        super.flagsChanged(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        recordAcceptanceRoute("performKeyEquivalent", event: event)
        return super.performKeyEquivalent(with: event)
    }
}

struct OmarchyVirtualMachineView: View {
    let layout: VMOmarchyWorkspaceLayout
    let profile: VMOmarchyProfile
    @AppStorage("omarchyClipboardEnabled") private var clipboardEnabled = true
    @AppStorage("omarchyMicrophoneEnabled") private var microphoneEnabled = false
    @AppStorage("omarchyNotificationsEnabled") private var notificationsEnabled = false
    @State private var lifecycle = OmarchyMachineLifecycle()
    @State private var sessionID = UUID()
    @State private var keyboardIntegration: OmarchyKeyboardIntegrationState = .accessibilityRequired
    @State private var integration: VMOmarchyIntegrationState = .connecting
    @State private var stopTimeoutTask: Task<Void, Never>?
    @State private var recoveryPoints: [VMOmarchyRecoveryPoint] = []
    @State private var recoveryOperation: RecoveryOperation = .idle
    @State private var pendingRestore: VMOmarchyRecoveryPoint?
    @State private var factoryChannel: FactoryChannelViewState = .idle
    @State private var importingFiles = false
    @State private var notice: UserNotice?
    @State private var recordedIntegrationSignature = ""
    @State private var sharedFolderProbe: VMOmarchySharedFolderProbeState = .notRun
    @State private var clipboardProbe: OmarchyClipboardProbeState = .notRun
    @State private var dynamicDisplayProbe: OmarchyDynamicDisplayProbeState = .notRun
    @State private var ownerSetupForm = OmarchyOwnerSetupForm()
    @State private var ownerSetupPhase: OmarchyOwnerSetupPhase = .editing
    @State private var ownerProvisioningSubmission: OmarchyOwnerProvisioningSubmission?
    @State private var automaticOwnerProvisioningStarted = false
    @State private var ownerProvisioningDetail: String?

    private var phase: Phase { lifecycle.phase }

    var body: some View {
        ZStack {
            OmarchyVirtualMachineRepresentable(
                layout: layout,
                profile: profile,
                clipboardEnabled: clipboardEnabled,
                notificationsEnabled: notificationsEnabled,
                microphoneEnabled: microphoneEnabled,
                sessionID: sessionID,
                keyboardIntegrationChanged: { keyboardIntegration = $0 },
                integrationChanged: handleIntegrationChange,
                sharedFolderProbeChanged: handleSharedFolderProbeChange,
                clipboardProbeChanged: handleClipboardProbeChange,
                dynamicDisplayProbeChanged: handleDynamicDisplayProbeChange,
                ownerProvisioningSubmission: ownerProvisioningSubmission,
                ownerProvisioningCompleted: handleOwnerProvisioningCompletion,
                ownerProvisioningProgressChanged: {
                    ownerProvisioningDetail = $0.displayMessage
                    if ownerSetupPhase == .editing {
                        ownerSetupPhase = .finishing
                    }
                },
                phaseChanged: handlePhaseChange
            )
            .id(sessionID)
            if phase != .running {
                statusOverlay
            }
            if ownerSetupAvailable {
                OmarchyOwnerSetupView(
                    form: $ownerSetupForm,
                    phase: ownerSetupPhase,
                    provisioningDetail: ownerProvisioningDetail,
                    submit: submitOwnerSetup
                )
            }
        }
        .background(.black)
        .dropDestination(for: URL.self) { urls, _ in
            importFiles(urls)
            return !urls.isEmpty
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                integrationMenu
                updatesMenu
                recoveryMenu
                Button("Open Shared Folder", systemImage: "folder") {
                    NSWorkspace.shared.open(layout.shared)
                }
                Button("Import Files", systemImage: "square.and.arrow.down") {
                    chooseFilesToImport()
                }
                .disabled(importingFiles)
                if phase == .running {
                    Button("Pause Omarchy", systemImage: "pause.fill") {
                        handle(.pauseRequested)
                    }
                    Button("Restart Omarchy", systemImage: "arrow.clockwise") {
                        handle(.restartRequested)
                    }
                    Button("Stop Omarchy", systemImage: "stop.fill") {
                        handle(.stopRequested)
                    }
                }
                if phase == .paused {
                    Button("Resume Omarchy", systemImage: "play.fill") {
                        handle(.resumeRequested)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if keyboardIntegration != .enabled {
                HStack {
                    if keyboardIntegration == .requestingAccessibility {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Waiting for Accessibility permission")
                        Text("Turn on EZVM Omarchy in System Settings, then return here.")
                    } else {
                        Text("Allow Accessibility access so Command shortcuts stay inside Omarchy.")
                    }
                    Spacer()
                    Button(keyboardIntegration == .requestingAccessibility ? "Open System Settings" : "Enable") {
                        NotificationCenter.default.post(name: .omarchyRequestKeyboardPermission, object: sessionID)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.18))
            }
        }
        .onDisappear {
            stopTimeoutTask?.cancel()
            stopTimeoutTask = nil
        }
        .onAppear { refreshRecoveryPoints() }
        .confirmationDialog(
            "Restore \(pendingRestore?.name ?? "this recovery point")?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore Omarchy", role: .destructive) {
                guard let point = pendingRestore else { return }
                pendingRestore = nil
                restore(point)
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("Omarchy must remain stopped. The current workspace will be replaced transactionally; an interrupted restore is rolled back automatically.")
        }
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var integrationMenu: some View {
        Menu {
            switch integration {
            case .connecting:
                Text("Connecting to Guest Agent…")
            case .authenticating:
                Text("Authenticating Guest Agent…")
            case .disconnected(let reason):
                Text("Guest Agent unavailable")
                Text(reason).foregroundStyle(.secondary)
            case .ready(let status):
                Text("Agent \(status.agentVersion) • \(status.hostName)")
                let assessment = VMOmarchyIntegrationAssessment.evaluate(
                    status: status,
                    requiredCapabilities: profile.requiredGuestCapabilities
                )
                if assessment.provisioningPending {
                    Text("Complete Omarchy owner setup")
                } else if !assessment.desktopSessionActive {
                    Text("Waiting for Omarchy desktop")
                } else if !assessment.missingCapabilities.isEmpty {
                    Text("Missing: \(assessment.missingCapabilities.joined(separator: ", "))")
                } else {
                    Text("Omarchy desktop integration ready")
                }
                if !status.addresses.isEmpty { Text(status.addresses.joined(separator: ", ")) }
                if status.capabilities.contains("shared-folders-v1") {
                    Text("Shared folder mounted at /mnt/ezvm-shared")
                } else {
                    Text("Shared folder is not mounted in Omarchy")
                }
                if !clipboardEnabled {
                    Text("Clipboard sharing is off")
                } else if status.capabilities.contains("clipboard-agent-text-v1") {
                    Text(status.capabilities.contains("clipboard-agent-image-v1")
                        ? "Authenticated text and image clipboard ready"
                        : "Authenticated text clipboard ready")
                } else if status.capabilities.contains("clipboard-text-v1") {
                    Text(status.capabilities.contains("clipboard-image-v1")
                        ? "Text and image clipboard ready (compatibility mode)"
                        : "Text clipboard ready (compatibility mode)")
                } else {
                    Text("Clipboard session integration is not ready")
                }
                Text("Capabilities: \(status.capabilities.sorted().joined(separator: ", "))")
            }
            Divider()
            Toggle("Share Clipboard", isOn: $clipboardEnabled)
            Toggle("Mirror Notifications to macOS", isOn: notificationsBinding)
            Text(notificationsEnabled
                ? "Omarchy notifications appear in macOS Notification Center"
                : "Notification mirroring is off")
            Toggle("Share Mac Microphone", isOn: microphoneBinding)
            Text(microphoneEnabled
                ? "Microphone will be available after Omarchy restarts"
                : "Microphone sharing is off")
            Divider()
            Button("Export Diagnostics…", systemImage: "square.and.arrow.up") {
                exportDiagnostics()
            }
        } label: {
            Label("Integration", systemImage: integrationReady ? "checkmark.circle.fill" : "exclamationmark.circle")
        }
        .help(integrationReady ? "Omarchy integration is ready" : "Omarchy integration is not ready")
    }

    @ViewBuilder
    private var recoveryMenu: some View {
        Menu {
            switch recoveryOperation {
            case .idle:
                if phase == .stopped {
                    Button("Create Protected Backup", systemImage: "externaldrive.badge.plus") {
                        createProtectedBackup()
                    }
                } else {
                    Text("Stop Omarchy to create or restore backups")
                }
            case .working(let message):
                Text(message)
            case .failed(let message):
                Text(message)
                Button("Dismiss") { recoveryOperation = .idle }
            }
            if !recoveryPoints.isEmpty {
                Divider()
                ForEach(recoveryPoints) { point in
                    Button {
                        pendingRestore = point
                    } label: {
                        Label(point.name, systemImage: point.isProtected ? "lock.shield" : "clock.arrow.circlepath")
                    }
                    .disabled(phase != .stopped || recoveryOperation.isWorking)
                }
            }
        } label: {
            Label("Recovery", systemImage: recoveryOperation.isFailed ? "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90" : "clock.arrow.circlepath")
        }
        .help("Create or restore protected Omarchy recovery points")
    }

    private var integrationReady: Bool {
        if case .ready(let status) = integration {
            return VMOmarchyIntegrationAssessment.evaluate(
                status: status,
                requiredCapabilities: profile.requiredGuestCapabilities
            ).isReady
        }
        return false
    }

    private var microphoneBinding: Binding<Bool> {
        Binding(
            get: { microphoneEnabled },
            set: { enabled in
                requestMicrophoneSharing(enabled)
            }
        )
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { notificationsEnabled },
            set: { enabled in requestNotificationMirroring(enabled) }
        )
    }

    private func requestNotificationMirroring(_ enabled: Bool) {
        guard enabled != notificationsEnabled else { return }
        guard enabled else {
            notificationsEnabled = false
            return
        }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch OmarchyNotificationPermissionPolicy.action(for: settings.authorizationStatus) {
            case .enable:
                notificationsEnabled = true
            case .request:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
                notificationsEnabled = granted
                if !granted { explainDeniedNotificationAccess() }
            case .openSystemSettings:
                explainDeniedNotificationAccess()
            }
        }
    }

    private func explainDeniedNotificationAccess() {
        notificationsEnabled = false
        notice = UserNotice(
            title: "Notification Access Is Off",
            message: "Allow EZVM Omarchy in System Settings → Notifications, then enable mirroring again."
        )
        NSWorkspace.shared.open(OmarchyNotificationPermissionPolicy.settingsURL)
    }

    private func requestMicrophoneSharing(_ enabled: Bool) {
        guard enabled != microphoneEnabled else { return }
        guard enabled else {
            applyMicrophoneSharing(false)
            return
        }
        switch OmarchyMicrophonePermissionPolicy.action(
            for: AVCaptureDevice.authorizationStatus(for: .audio)
        ) {
        case .enable:
            applyMicrophoneSharing(true)
        case .request:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted {
                        applyMicrophoneSharing(true)
                    } else {
                        explainDeniedMicrophoneAccess(openSettings: true)
                    }
                }
            }
        case .openSystemSettings:
            explainDeniedMicrophoneAccess(openSettings: true)
        }
    }

    private func applyMicrophoneSharing(_ enabled: Bool) {
        microphoneEnabled = enabled
        guard phase == .running || phase == .paused else { return }
        notice = UserNotice(
            title: "Restart Omarchy to Apply",
            message: enabled
                ? "Restart Omarchy to make the Mac microphone available to Linux applications."
                : "Restart Omarchy to remove the Mac microphone from the virtual machine."
        )
    }

    private func explainDeniedMicrophoneAccess(openSettings: Bool) {
        microphoneEnabled = false
        notice = UserNotice(
            title: "Microphone Access Is Off",
            message: "Allow EZVM Omarchy under Privacy & Security → Microphone, then enable sharing again."
        )
        if openSettings {
            NSWorkspace.shared.open(OmarchyMicrophonePermissionPolicy.settingsURL)
        }
    }

    private var ownerSetupAvailable: Bool {
        guard case .ready(let status) = integration else { return false }
        return status.provisioningPending && status.capabilities.contains("owner-provisioning-v1")
    }

    private func submitOwnerSetup() {
        guard ownerSetupPhase != .submitting, ownerSetupPhase != .finishing else { return }
        do {
            let request = try ownerSetupForm.validatedRequest()
            ownerSetupPhase = .submitting
            ownerProvisioningSubmission = .init(request: request)
        } catch {
            ownerSetupPhase = .failed(error.localizedDescription)
        }
    }

    private func handleOwnerProvisioningCompletion(_ id: UUID, _ errorMessage: String?) {
        guard ownerProvisioningSubmission?.id == id else { return }
        ownerProvisioningSubmission = nil
        if let errorMessage {
            ownerSetupPhase = .failed(errorMessage)
        } else {
            ownerSetupForm.clearSecrets()
            ownerSetupPhase = .finishing
        }
    }

    @ViewBuilder
    private var updatesMenu: some View {
        Menu {
            Text("App updates are delivered separately from Omarchy and factory images.")
            Text("Guest updates run inside Omarchy; create a protected backup first.")
            Divider()
            switch factoryChannel {
            case .idle:
                Button("Check Signed Factory Channel", systemImage: "checkmark.shield") {
                    checkFactoryChannel()
                }
            case .checking:
                Text("Checking signed factory metadata…")
            case .current(let version):
                Text("Installed from current factory \(version)")
                Button("Check Again") { checkFactoryChannel() }
            case .untracked(let available):
                Text("Current workspace has no recorded factory version")
                Text("Signed channel factory: \(available)")
                Text("Factory images are only used for new installs and recovery.")
                Button("Check Again") { checkFactoryChannel() }
            case .different(let installed, let available):
                Text("Workspace factory: \(installed)")
                Text("Signed channel factory: \(available)")
                Text("The different channel image will not replace this workspace.")
                Button("Check Again") { checkFactoryChannel() }
            case .failed(let message):
                Text(message)
                Button("Try Again") { checkFactoryChannel() }
            }
        } label: {
            Label("Updates", systemImage: factoryChannel.needsAttention ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
        }
        .help("App, factory-image, and guest update status")
    }

    private func checkFactoryChannel() {
        guard factoryChannel != .checking else { return }
        guard let publicKey = FactoryTrustConfiguration.publicKey() else {
            factoryChannel = .failed("This build has no trusted factory signing key.")
            return
        }
        let workspace = VMOmarchyWorkspaceManager(layout: layout)
        let installedVersion = try? workspace.metadata().factoryImageVersion
        let installer = VMOmarchyFactoryInstaller(
            profile: profile,
            cacheDirectory: layout.cache,
            publicKey: publicKey,
            transport: VMOmarchyURLSessionTransport()
        )
        factoryChannel = .checking
        Task {
            do {
                let manifest = try await installer.fetchVerifiedManifest()
                switch VMOmarchyFactoryChannelState.assess(
                    installedVersion: installedVersion,
                    manifest: manifest
                ) {
                case .current(let version): factoryChannel = .current(version)
                case .untracked(let available): factoryChannel = .untracked(available)
                case .different(let installed, let available):
                    factoryChannel = .different(installed: installed, available: available)
                }
            } catch {
                factoryChannel = .failed(error.localizedDescription)
            }
        }
    }

    private func handleIntegrationChange(_ state: VMOmarchyIntegrationState) {
        integration = state
        guard case .ready(let status) = state else { return }
        startAutomaticOwnerProvisioningIfNeeded(status)
        if !status.provisioningPending {
            ownerSetupForm.clearSecrets()
            ownerProvisioningSubmission = nil
            ownerSetupPhase = .editing
            ownerProvisioningDetail = nil
        }
        OmarchyAcceptanceObservationReporter.reportIfEnabled(
            status: status,
            requiredCapabilities: profile.requiredGuestCapabilities,
            layout: layout,
            sharedFolderRoundTrip: sharedFolderRoundTrip,
            clipboardRoundTrip: clipboardRoundTrip,
            dynamicDisplayRoundTrip: dynamicDisplayRoundTrip
        )
        let signature = ([status.omarchyRevision ?? "", status.agentVersion]
            + status.capabilities.sorted()).joined(separator: "\u{1f}")
        guard signature != recordedIntegrationSignature else { return }
        recordedIntegrationSignature = signature
        let manager = VMOmarchyWorkspaceManager(layout: layout)
        omarchyMetadataQueue.async {
            do {
                try manager.recordGuestIntegration(
                    omarchyRevision: status.omarchyRevision,
                    agentVersion: status.agentVersion,
                    capabilities: status.capabilities
                )
            } catch {
                NSLog("Could not record Omarchy integration metadata: %@", error.localizedDescription)
            }
        }
    }

    private func startAutomaticOwnerProvisioningIfNeeded(_ status: VMOmarchyGuestStatus) {
        guard status.provisioningPending,
              status.capabilities.contains("owner-provisioning-v1"),
              !automaticOwnerProvisioningStarted,
              let password = OmarchyWorkspaceConfiguration.acceptanceOwnerProvisioningPassword()
        else { return }

        automaticOwnerProvisioningStarted = true
        var form = ownerSetupForm
        form.password = password
        form.passwordConfirmation = password
        do {
            let request = try form.validatedRequest()
            ownerSetupForm = form
            ownerSetupPhase = .submitting
            ownerProvisioningSubmission = .init(request: request)
        } catch {
            form.clearSecrets()
            ownerSetupForm = form
            ownerSetupPhase = .failed(error.localizedDescription)
        }
    }

    private var sharedFolderRoundTrip: VMOmarchySharedFolderRoundTrip? {
        guard case .passed(let result) = sharedFolderProbe else { return nil }
        return result
    }

    private func handleSharedFolderProbeChange(_ state: VMOmarchySharedFolderProbeState) {
        sharedFolderProbe = state
        guard case .ready(let status) = integration else { return }
        OmarchyAcceptanceObservationReporter.reportIfEnabled(
            status: status,
            requiredCapabilities: profile.requiredGuestCapabilities,
            layout: layout,
            sharedFolderRoundTrip: sharedFolderRoundTrip,
            clipboardRoundTrip: clipboardRoundTrip,
            dynamicDisplayRoundTrip: dynamicDisplayRoundTrip
        )
    }

    private var clipboardRoundTrip: OmarchyClipboardRoundTrip? {
        guard case .passed(let result) = clipboardProbe else { return nil }
        return result
    }

    private func handleClipboardProbeChange(_ state: OmarchyClipboardProbeState) {
        clipboardProbe = state
        guard case .ready(let status) = integration else { return }
        OmarchyAcceptanceObservationReporter.reportIfEnabled(
            status: status,
            requiredCapabilities: profile.requiredGuestCapabilities,
            layout: layout,
            sharedFolderRoundTrip: sharedFolderRoundTrip,
            clipboardRoundTrip: clipboardRoundTrip,
            dynamicDisplayRoundTrip: dynamicDisplayRoundTrip
        )
    }

    private var dynamicDisplayRoundTrip: OmarchyDynamicDisplayRoundTrip? {
        guard case .passed(let result) = dynamicDisplayProbe else { return nil }
        return result
    }

    private func handleDynamicDisplayProbeChange(_ state: OmarchyDynamicDisplayProbeState) {
        dynamicDisplayProbe = state
        guard case .ready(let status) = integration else { return }
        OmarchyAcceptanceObservationReporter.reportIfEnabled(
            status: status,
            requiredCapabilities: profile.requiredGuestCapabilities,
            layout: layout,
            sharedFolderRoundTrip: sharedFolderRoundTrip,
            clipboardRoundTrip: clipboardRoundTrip,
            dynamicDisplayRoundTrip: dynamicDisplayRoundTrip
        )
    }

    private func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Import into Omarchy"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Export EZVM Omarchy Diagnostics"
        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.nameFieldStringValue = "EZVM-Omarchy-Diagnostics-\(date).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let report = VMOmarchyDiagnostics().report(
                layout: layout,
                appVersion: appVersion,
                integrationState: integration
            )
            try report.encoded().write(to: destination, options: .atomic)
            notice = UserNotice(title: "Diagnostics Exported", message: destination.lastPathComponent)
        } catch {
            notice = UserNotice(title: "Diagnostics Export Failed", message: error.localizedDescription)
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !importingFiles else { return }
        importingFiles = true
        let importer = VMOmarchySharedFolderImporter(layout: layout)
        DispatchQueue.global(qos: .userInitiated).async {
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            let result = Result { try importer.importFiles(urls) }
            DispatchQueue.main.async {
                importingFiles = false
                switch result {
                case .success(let files):
                    let names = files.map(\.destinationURL.lastPathComponent).joined(separator: ", ")
                    notice = UserNotice(
                        title: "Files Ready in Omarchy",
                        message: "Imported \(files.count) file(s): \(names). Open /mnt/ezvm-shared in Omarchy."
                    )
                case .failure(let error):
                    notice = UserNotice(title: "Import Failed", message: error.localizedDescription)
                }
            }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch phase {
        case .starting:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Starting Omarchy…").font(.headline)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .running:
            EmptyView()
        case .pausing:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Pausing Omarchy…").font(.headline)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .paused:
            VStack(spacing: 14) {
                Text("Omarchy is paused").font(.headline)
                Button("Resume Omarchy", systemImage: "play.fill") {
                    handle(.resumeRequested)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .resuming:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Resuming Omarchy…").font(.headline)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .stopping:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Stopping Omarchy…").font(.headline)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .stopped:
            VStack(spacing: 14) {
                Text("Omarchy is stopped").font(.headline)
                Button("Start Omarchy", systemImage: "play.fill") {
                    handle(.startRequested)
                }
                .buttonStyle(.borderedProminent)
                .disabled(recoveryOperation.isWorking)
            }
            .padding(26)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        case .failed(let message):
            ContentUnavailableView(
                "Omarchy could not start",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .padding(30)
            .background(.regularMaterial)
        }
    }

    private func handlePhaseChange(_ phase: Phase) {
        switch phase {
        case .running: handle(.machineStarted)
        case .paused: handle(.machinePaused)
        case .stopped:
            handle(.machineStopped)
            refreshRecoveryPoints()
        case .failed(let message): handle(.machineFailed(message))
        case .starting, .pausing, .resuming, .stopping: break
        }
    }

    private func refreshRecoveryPoints() {
        recoveryPoints = VMOmarchyRecoveryManager(
            workspaceManager: VMOmarchyWorkspaceManager(layout: layout)
        ).recoveryPoints()
    }

    private func createProtectedBackup() {
        guard phase == .stopped, !recoveryOperation.isWorking else { return }
        recoveryOperation = .working("Creating protected backup…")
        let manager = VMOmarchyRecoveryManager(
            workspaceManager: VMOmarchyWorkspaceManager(layout: layout)
        )
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try manager.createProtectedBackup() }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    recoveryOperation = .idle
                    refreshRecoveryPoints()
                case .failure(let error):
                    recoveryOperation = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func restore(_ point: VMOmarchyRecoveryPoint) {
        guard phase == .stopped, !recoveryOperation.isWorking else { return }
        recoveryOperation = .working("Restoring \(point.name)…")
        let manager = VMOmarchyRecoveryManager(
            workspaceManager: VMOmarchyWorkspaceManager(layout: layout)
        )
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try manager.restore(id: point.id) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    recoveryOperation = .idle
                    refreshRecoveryPoints()
                case .failure(let error):
                    recoveryOperation = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func handle(_ event: OmarchyMachineLifecycle.Event) {
        for effect in lifecycle.handle(event) {
            switch effect {
            case .requestStop:
                NotificationCenter.default.post(name: .omarchyRequestStop, object: sessionID)
            case .requestPause:
                NotificationCenter.default.post(name: .omarchyRequestPause, object: sessionID)
            case .requestResume:
                NotificationCenter.default.post(name: .omarchyRequestResume, object: sessionID)
            case .startNewSession:
                sessionID = UUID()
            case .scheduleForceStop:
                stopTimeoutTask?.cancel()
                stopTimeoutTask = Task {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { handle(.stopTimedOut) }
                }
            case .cancelForceStop:
                stopTimeoutTask?.cancel()
                stopTimeoutTask = nil
            case .forceStop:
                NotificationCenter.default.post(name: .omarchyForceStop, object: sessionID)
            }
        }
    }

    enum Phase: Equatable {
        case starting
        case running
        case pausing
        case paused
        case resuming
        case stopping
        case stopped
        case failed(String)
    }

    private enum RecoveryOperation: Equatable {
        case idle
        case working(String)
        case failed(String)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    private enum FactoryChannelViewState: Equatable {
        case idle
        case checking
        case current(String)
        case untracked(String)
        case different(installed: String, available: String)
        case failed(String)

        var needsAttention: Bool {
            switch self {
            case .untracked, .different, .failed: true
            case .idle, .checking, .current: false
            }
        }
    }

    private struct UserNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
}

enum OmarchyMicrophonePermissionAction: Equatable {
    case enable
    case request
    case openSystemSettings
}

enum OmarchyMicrophonePermissionPolicy {
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )!

    static func action(for status: AVAuthorizationStatus) -> OmarchyMicrophonePermissionAction {
        switch status {
        case .authorized: .enable
        case .notDetermined: .request
        case .denied, .restricted: .openSystemSettings
        @unknown default: .openSystemSettings
        }
    }
}

enum OmarchyClipboardActivationPolicy {
    static func shouldRun(
        enabled: Bool,
        capabilities: Set<String>,
        desktopSessionActive: Bool,
        provisioningPending: Bool,
        probeOwnsTransport: Bool
    ) -> Bool {
        enabled
            && !probeOwnsTransport
            && desktopSessionActive
            && !provisioningPending
            && Set(["clipboard-agent-text-v1", "clipboard-agent-image-v1"])
                .isSubset(of: capabilities)
    }
}

struct OmarchyMachineLifecycle: Equatable {
    var phase: OmarchyVirtualMachineView.Phase = .starting
    private(set) var restartAfterStop = false

    enum Event: Equatable {
        case machineStarted
        case pauseRequested
        case machinePaused
        case resumeRequested
        case startRequested
        case stopRequested
        case restartRequested
        case machineStopped
        case machineFailed(String)
        case stopTimedOut
    }

    enum Effect: Equatable {
        case requestStop
        case requestPause
        case requestResume
        case startNewSession
        case scheduleForceStop
        case cancelForceStop
        case forceStop
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .machineStarted:
            phase = .running
        case .pauseRequested:
            guard phase == .running else { return [] }
            phase = .pausing
            return [.requestPause]
        case .machinePaused:
            guard phase == .pausing else { return [] }
            phase = .paused
        case .resumeRequested:
            guard phase == .paused else { return [] }
            phase = .resuming
            return [.requestResume]
        case .startRequested:
            guard phase == .stopped || isFailed else { return [] }
            restartAfterStop = false
            phase = .starting
            return [.startNewSession]
        case .stopRequested:
            guard phase == .running || phase == .paused else { return [] }
            restartAfterStop = false
            phase = .stopping
            return [.requestStop, .scheduleForceStop]
        case .restartRequested:
            guard phase == .running || phase == .paused else { return [] }
            restartAfterStop = true
            phase = .stopping
            return [.requestStop, .scheduleForceStop]
        case .machineStopped:
            if restartAfterStop {
                restartAfterStop = false
                phase = .starting
                return [.cancelForceStop, .startNewSession]
            }
            phase = .stopped
            return [.cancelForceStop]
        case .machineFailed(let message):
            restartAfterStop = false
            phase = .failed(message)
            return [.cancelForceStop]
        case .stopTimedOut:
            guard phase == .stopping else { return [] }
            return [.forceStop]
        }
        return []
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}

private struct OmarchyVirtualMachineRepresentable: NSViewRepresentable {
    let layout: VMOmarchyWorkspaceLayout
    let profile: VMOmarchyProfile
    let clipboardEnabled: Bool
    let notificationsEnabled: Bool
    let microphoneEnabled: Bool
    let sessionID: UUID
    let keyboardIntegrationChanged: (OmarchyKeyboardIntegrationState) -> Void
    let integrationChanged: (VMOmarchyIntegrationState) -> Void
    let sharedFolderProbeChanged: (VMOmarchySharedFolderProbeState) -> Void
    let clipboardProbeChanged: (OmarchyClipboardProbeState) -> Void
    let dynamicDisplayProbeChanged: (OmarchyDynamicDisplayProbeState) -> Void
    let ownerProvisioningSubmission: OmarchyOwnerProvisioningSubmission?
    let ownerProvisioningCompleted: (UUID, String?) -> Void
    let ownerProvisioningProgressChanged: (VMOmarchyOwnerProvisioningProgress) -> Void
    let phaseChanged: (OmarchyVirtualMachineView.Phase) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionID: sessionID,
            layout: layout,
            requiredGuestCapabilities: profile.requiredGuestCapabilities,
            clipboardEnabled: clipboardEnabled,
            notificationsEnabled: notificationsEnabled,
            keyboardIntegrationChanged: keyboardIntegrationChanged,
            integrationChanged: integrationChanged,
            sharedFolderProbeChanged: sharedFolderProbeChanged,
            clipboardProbeChanged: clipboardProbeChanged,
            dynamicDisplayProbeChanged: dynamicDisplayProbeChanged,
            ownerProvisioningCompleted: ownerProvisioningCompleted,
            ownerProvisioningProgressChanged: ownerProvisioningProgressChanged,
            phaseChanged: phaseChanged
        )
    }

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = OmarchyVirtualMachineInputView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        do {
            let configuration = try VMOmarchyVirtualMachineBuilder.makeConfiguration(
                layout: layout,
                profile: profile,
                microphoneEnabled: microphoneEnabled
            )
            let machine = VZVirtualMachine(configuration: configuration)
            machine.delegate = context.coordinator
            context.coordinator.machine = machine
            context.coordinator.machineView = view
            OmarchyApplicationTerminationController.shared.register(machine)
            context.coordinator.beginObservingCommands()
            view.virtualMachine = machine
            context.coordinator.installKeyboardBridge(for: view)
            machine.start { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        context.coordinator.startIntegration(layout: layout)
                        context.coordinator.phaseChanged(.running)
                    case .failure(let error): context.coordinator.phaseChanged(.failed(error.localizedDescription))
                    }
                }
            }
        } catch {
            DispatchQueue.main.async {
                context.coordinator.phaseChanged(.failed(error.localizedDescription))
            }
        }
        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        context.coordinator.setClipboardEnabled(clipboardEnabled)
        context.coordinator.setNotificationsEnabled(notificationsEnabled)
        if let ownerProvisioningSubmission {
            context.coordinator.submitOwnerProvisioning(ownerProvisioningSubmission)
        }
    }

    static func dismantleNSView(_ nsView: VZVirtualMachineView, coordinator: Coordinator) {
        coordinator.stopImmediately()
        nsView.virtualMachine = nil
    }

    final class Coordinator: NSObject, VZVirtualMachineDelegate {
        var machine: VZVirtualMachine?
        let sessionID: UUID
        let layout: VMOmarchyWorkspaceLayout
        let requiredGuestCapabilities: [String]
        private var clipboardEnabled: Bool
        private var notificationsEnabled: Bool
        let keyboardIntegrationChanged: (OmarchyKeyboardIntegrationState) -> Void
        let integrationChanged: (VMOmarchyIntegrationState) -> Void
        let sharedFolderProbeChanged: (VMOmarchySharedFolderProbeState) -> Void
        let clipboardProbeChanged: (OmarchyClipboardProbeState) -> Void
        let dynamicDisplayProbeChanged: (OmarchyDynamicDisplayProbeState) -> Void
        let ownerProvisioningCompleted: (UUID, String?) -> Void
        let ownerProvisioningProgressChanged: (VMOmarchyOwnerProvisioningProgress) -> Void
        let phaseChanged: (OmarchyVirtualMachineView.Phase) -> Void
        private var stopObserver: NSObjectProtocol?
        private var pauseObserver: NSObjectProtocol?
        private var resumeObserver: NSObjectProtocol?
        private var keyboardPermissionObserver: NSObjectProtocol?
        private var forceStopObserver: NSObjectProtocol?
        private var keyboardBridge: OmarchyFocusedCommandBridge?
        private var integrationClient: VMOmarchyGuestAgentClient?
        private var agentClipboardController: OmarchyAgentClipboardController?
        private var notificationController: OmarchyNotificationController?
        private var notificationAcceptanceProbeTask: Task<Void, Never>?
        private var notificationAcceptanceProbeStarted = false
        private var notificationAcceptanceProbeCompleted = false
        private var expectedAcceptanceNotificationTitle: String?
        private var latestGuestStatus: VMOmarchyGuestStatus?
        private var clipboardProbeOwnsTransport = false
        private var sharedFolderProbeTask: Task<Void, Never>?
        private var sharedFolderProbePassed = false
        private var clipboardProbeTask: Task<Void, Never>?
        private var clipboardProbePassed = false
        weak var machineView: VZVirtualMachineView?
        private var dynamicDisplayProbeTask: Task<Void, Never>?
        private var dynamicDisplayProbePassed = false
        private var automaticLockProbe = OmarchyLockAcceptanceState()
        private var automaticPauseResumeProbeStarted = false
        private var automaticRecoveryAfterResume = false
        private var automaticRecoveryStage = AutomaticRecoveryStage.idle
        private var recoveryBaselineStatus: VMOmarchyGuestStatus?
        private var guestRestartAcceptanceState = OmarchyGuestRestartAcceptanceState()
        private var guestRestartUnlockTimeoutTask: Task<Void, Never>?
        private var hostWakeInteractiveTask: Task<Void, Never>?
        private var automaticCommandSpaceProbeStarted = false
        private var automaticFullScreenProbeStarted = false
        private var fullScreenProbe: OmarchyFullScreenAcceptanceProbe?
        private var lastOwnerProvisioningSubmissionID: UUID?
        private var ownerProgressFetchInFlight = false

        private enum AutomaticRecoveryStage {
            case idle
            case waitingForPostResumeReady
            case waitingForAgentDisconnect
            case waitingForAgentReady
            case waitingForGuestDisconnect
            case waitingForGuestReady
            case complete
        }

        init(
            sessionID: UUID,
            layout: VMOmarchyWorkspaceLayout,
            requiredGuestCapabilities: [String],
            clipboardEnabled: Bool,
            notificationsEnabled: Bool,
            keyboardIntegrationChanged: @escaping (OmarchyKeyboardIntegrationState) -> Void,
            integrationChanged: @escaping (VMOmarchyIntegrationState) -> Void,
            sharedFolderProbeChanged: @escaping (VMOmarchySharedFolderProbeState) -> Void,
            clipboardProbeChanged: @escaping (OmarchyClipboardProbeState) -> Void,
            dynamicDisplayProbeChanged: @escaping (OmarchyDynamicDisplayProbeState) -> Void,
            ownerProvisioningCompleted: @escaping (UUID, String?) -> Void,
            ownerProvisioningProgressChanged: @escaping (VMOmarchyOwnerProvisioningProgress) -> Void,
            phaseChanged: @escaping (OmarchyVirtualMachineView.Phase) -> Void
        ) {
            self.sessionID = sessionID
            self.layout = layout
            self.requiredGuestCapabilities = requiredGuestCapabilities
            self.clipboardEnabled = clipboardEnabled
            self.notificationsEnabled = notificationsEnabled
            self.keyboardIntegrationChanged = keyboardIntegrationChanged
            self.integrationChanged = integrationChanged
            self.sharedFolderProbeChanged = sharedFolderProbeChanged
            self.clipboardProbeChanged = clipboardProbeChanged
            self.dynamicDisplayProbeChanged = dynamicDisplayProbeChanged
            self.ownerProvisioningCompleted = ownerProvisioningCompleted
            self.ownerProvisioningProgressChanged = ownerProvisioningProgressChanged
            self.phaseChanged = phaseChanged
        }

        func submitOwnerProvisioning(_ submission: OmarchyOwnerProvisioningSubmission) {
            guard lastOwnerProvisioningSubmissionID != submission.id else { return }
            lastOwnerProvisioningSubmissionID = submission.id
            guard let integrationClient else {
                ownerProvisioningCompleted(submission.id, "The Guest Agent is not ready for owner setup.")
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await integrationClient.provisionOwner(submission.request)
                    ownerProvisioningCompleted(submission.id, nil)
                } catch {
                    ownerProvisioningCompleted(submission.id, error.localizedDescription)
                }
            }
        }

        private func refreshOwnerProvisioningProgressIfNeeded(_ status: VMOmarchyGuestStatus) {
            guard status.provisioningPending, !ownerProgressFetchInFlight,
                  let integrationClient else { return }
            ownerProgressFetchInFlight = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { ownerProgressFetchInFlight = false }
                if let progress = try? await integrationClient.ownerProvisioningProgress() {
                    ownerProvisioningProgressChanged(progress)
                }
            }
        }

        deinit {
            if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) }
            if let pauseObserver { NotificationCenter.default.removeObserver(pauseObserver) }
            if let resumeObserver { NotificationCenter.default.removeObserver(resumeObserver) }
            if let keyboardPermissionObserver { NotificationCenter.default.removeObserver(keyboardPermissionObserver) }
            if let forceStopObserver { NotificationCenter.default.removeObserver(forceStopObserver) }
            hostWakeInteractiveTask?.cancel()
        }

        func beginObservingCommands() {
            stopObserver = NotificationCenter.default.addObserver(
                forName: .omarchyRequestStop,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, notification.object as? UUID == self.sessionID else { return }
                self.requestStop()
            }
            pauseObserver = NotificationCenter.default.addObserver(
                forName: .omarchyRequestPause,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, notification.object as? UUID == self.sessionID else { return }
                self.pause(automaticResume: false)
            }
            resumeObserver = NotificationCenter.default.addObserver(
                forName: .omarchyRequestResume,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, notification.object as? UUID == self.sessionID else { return }
                self.resume()
            }
            keyboardPermissionObserver = NotificationCenter.default.addObserver(
                forName: .omarchyRequestKeyboardPermission,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, notification.object as? UUID == self.sessionID else { return }
                if let keyboardBridge = self.keyboardBridge {
                    keyboardBridge.requestPermission()
                } else {
                    OmarchyFocusedCommandBridge.requestAccessibilityAccess()
                }
            }
            forceStopObserver = NotificationCenter.default.addObserver(
                forName: .omarchyForceStop,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, notification.object as? UUID == self.sessionID else { return }
                self.forceStop()
            }
        }

        func installKeyboardBridge(for view: VZVirtualMachineView) {
            let bridge = OmarchyFocusedCommandBridge(
                focusProbe: { [weak view] in
                    guard let view, let window = view.window else { return false }
                    guard window.isKeyWindow, NSApp.keyWindow === window, NSApp.modalWindow == nil,
                          window.attachedSheet == nil else { return false }
                    guard let responder = window.firstResponder as? NSView else { return false }
                    return responder === view || responder.isDescendant(of: view)
                },
                stateChanged: keyboardIntegrationChanged,
                redirectedCommandChord: { [weak self] keyCode, flags in
                    guard let client = self?.integrationClient else { return false }
                    Task { @MainActor in
                        do {
                            try await client.injectMacCommandChord(
                                keyCode: UInt16(keyCode),
                                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
                            )
                        } catch {
                            NSLog(
                                "Omarchy Command chord Agent forwarding failed: %@",
                                error.localizedDescription
                            )
                        }
                    }
                    return true
                },
                commandSpaceCaptured: { [weak self, weak view] in
                    guard let self else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        OmarchyAcceptanceObservationReporter.reportCommandSuperIfEnabled(
                            layout: self.layout,
                            applicationActive: NSApp.isActive,
                            virtualMachineWindowKey: view?.window?.isKeyWindow == true
                        )
                    }
                }
            )
            keyboardBridge = bridge
            bridge.start()
        }

        func startIntegration(layout: VMOmarchyWorkspaceLayout) {
            guard let socket = machine?.socketDevices.first as? VZVirtioSocketDevice else {
                integrationChanged(.disconnected("The VM has no Virtio Socket device."))
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let client = try VMOmarchyGuestAgentClient(
                        device: socket,
                        layout: layout,
                        hostPowerChanged: { [weak self] event in
                            guard let self else { return }
                            Task { @MainActor [weak self] in
                                self?.handleHostPowerEvent(event)
                            }
                        },
                        stateChanged: { [weak self] state in
                            guard let self else { return }
                            self.integrationChanged(state)
                            switch state {
                            case .ready(let status):
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    // Record every authenticated status transition here. SwiftUI
                                    // can coalesce a short-lived locked status before the parent
                                    // view's onChange handler runs, which would make real lifecycle
                                    // evidence omit a lock that the recovery state machine observed.
                                    OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
                                        status: status,
                                        layout: self.layout
                                    )
                                    self.latestGuestStatus = status
                                    self.configureAgentClipboard(for: status)
                                    self.configureNotifications(for: status)
                                    self.handleAutomaticRecoveryReady(status)
                                    self.refreshOwnerProvisioningProgressIfNeeded(status)
                                }
                            case .disconnected:
                                Task { @MainActor [weak self] in
                                    self?.latestGuestStatus = nil
                                    self?.stopAgentClipboard()
                                    self?.stopNotifications()
                                    self?.handleAutomaticRecoveryDisconnect()
                                }
                            case .connecting, .authenticating:
                                break
                            }
                            if case .ready(let status) = state,
                               VMOmarchyIntegrationAssessment.evaluate(
                                status: status,
                                requiredCapabilities: self.requiredGuestCapabilities
                               ).isReady {
                                self.startSharedFolderProbeIfNeeded(layout: layout)
                            }
                        }
                    )
                    self.integrationClient = client
                    client.start()
                } catch {
                    self.integrationChanged(.disconnected(error.localizedDescription))
                }
            }
        }

        @MainActor
        private func configureAgentClipboard(for status: VMOmarchyGuestStatus) {
            latestGuestStatus = status
            guard OmarchyClipboardActivationPolicy.shouldRun(
                enabled: clipboardEnabled,
                capabilities: Set(status.capabilities),
                desktopSessionActive: status.desktopSessionActive,
                provisioningPending: status.provisioningPending,
                probeOwnsTransport: clipboardProbeOwnsTransport
            ),
                  let integrationClient else {
                stopAgentClipboard()
                return
            }
            guard agentClipboardController == nil else { return }
            let controller = OmarchyAgentClipboardController(
                client: integrationClient,
                sharedDirectory: layout.shared
            )
            agentClipboardController = controller
            controller.start()
        }

        @MainActor
        func setClipboardEnabled(_ enabled: Bool) {
            guard clipboardEnabled != enabled else { return }
            clipboardEnabled = enabled
            guard let latestGuestStatus else {
                stopAgentClipboard()
                return
            }
            configureAgentClipboard(for: latestGuestStatus)
        }

        @MainActor
        private func stopAgentClipboard() {
            agentClipboardController?.stop()
            agentClipboardController = nil
        }

        @MainActor
        private func configureNotifications(for status: VMOmarchyGuestStatus) {
            guard OmarchyNotificationActivationPolicy.shouldRun(
                enabled: notificationsEnabled,
                capabilities: status.capabilities,
                desktopSessionActive: status.desktopSessionActive,
                provisioningPending: status.provisioningPending
            ), let integrationClient else {
                stopNotifications()
                return
            }
            guard notificationController == nil else { return }
            let controller = OmarchyNotificationController(
                client: integrationClient,
                bootID: status.bootID,
                deliverySucceeded: { [weak self] notification in
                    guard let self,
                          notification.title == self.expectedAcceptanceNotificationTitle else { return }
                    self.expectedAcceptanceNotificationTitle = nil
                    self.notificationAcceptanceProbeCompleted = true
                    OmarchyAcceptanceObservationReporter.reportDesktopNotificationIfEnabled(
                        notification,
                        guestBootID: status.bootID,
                        layout: self.layout
                    )
                    NSLog("Omarchy Guest notification was accepted by macOS Notification Center")
                }
            )
            notificationController = controller
            controller.start()
            startNotificationAcceptanceProbeIfNeeded(client: integrationClient)
        }

        @MainActor
        func setNotificationsEnabled(_ enabled: Bool) {
            guard notificationsEnabled != enabled else { return }
            notificationsEnabled = enabled
            guard let latestGuestStatus else {
                stopNotifications()
                return
            }
            configureNotifications(for: latestGuestStatus)
        }

        @MainActor
        private func stopNotifications() {
            notificationController?.stop()
            notificationController = nil
            notificationAcceptanceProbeTask?.cancel()
            notificationAcceptanceProbeTask = nil
            expectedAcceptanceNotificationTitle = nil
            if !notificationAcceptanceProbeCompleted {
                notificationAcceptanceProbeStarted = false
            }
        }

        private func startNotificationAcceptanceProbeIfNeeded(
            client: VMOmarchyGuestAgentClient
        ) {
            guard ProcessInfo.processInfo.environment[
                OmarchyWorkspaceConfiguration.acceptanceEnabledKey
            ] == "1", !notificationAcceptanceProbeStarted,
                  !notificationAcceptanceProbeCompleted else { return }
            notificationAcceptanceProbeStarted = true
            let title = "EZVM notification \(UUID().uuidString.lowercased())"
            expectedAcceptanceNotificationTitle = title
            notificationAcceptanceProbeTask = Task { @MainActor [weak self, weak client] in
                guard let self, let client else { return }
                do {
                    // Let the first poll establish its baseline before the
                    // synthetic Guest notification is created.
                    try await Task.sleep(for: .seconds(3))
                    try await OmarchyInputDiagnosticsAcceptanceProbe.sendDesktopNotification(
                        client: client,
                        sharedDirectory: self.layout.shared,
                        title: title
                    )
                    let deadline = ContinuousClock.now + .seconds(30)
                    while self.expectedAcceptanceNotificationTitle != nil,
                          ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    if self.expectedAcceptanceNotificationTitle != nil {
                        NSLog("Omarchy notification acceptance timed out")
                        self.expectedAcceptanceNotificationTitle = nil
                        self.notificationAcceptanceProbeStarted = false
                    }
                } catch is CancellationError {
                    return
                } catch {
                    NSLog("Omarchy notification acceptance failed: %@", error.localizedDescription)
                    self.expectedAcceptanceNotificationTitle = nil
                    self.notificationAcceptanceProbeStarted = false
                }
                self.notificationAcceptanceProbeTask = nil
            }
        }

        private func startSharedFolderProbeIfNeeded(layout: VMOmarchyWorkspaceLayout) {
            guard ProcessInfo.processInfo.environment[
                OmarchyWorkspaceConfiguration.acceptanceEnabledKey
            ] == "1", !sharedFolderProbePassed, sharedFolderProbeTask == nil,
                  let integrationClient else { return }
            sharedFolderProbeChanged(.running)
            sharedFolderProbeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await integrationClient.verifySharedFolderRoundTrip(
                        layout: layout
                    )
                    self.sharedFolderProbePassed = true
                    NSLog(
                        "Omarchy shared-folder round trip passed (host-to-guest %@, guest-to-host %@)",
                        result.hostToGuestSHA256,
                        result.guestToHostSHA256
                    )
                    self.sharedFolderProbeChanged(.passed(result))
                    self.startClipboardProbeIfNeeded(layout: layout)
                } catch {
                    NSLog("Omarchy shared-folder round trip failed: %@", error.localizedDescription)
                    self.sharedFolderProbeChanged(.failed(error.localizedDescription))
                }
                self.sharedFolderProbeTask = nil
            }
        }

        private func startClipboardProbeIfNeeded(layout: VMOmarchyWorkspaceLayout) {
            guard ProcessInfo.processInfo.environment[
                OmarchyWorkspaceConfiguration.acceptanceEnabledKey
            ] == "1", sharedFolderProbePassed, !clipboardProbePassed,
                  clipboardProbeTask == nil, let integrationClient else { return }
            // Claim clipboard transport ownership before scheduling the probe.
            // A ready-status callback is delivered on a separate MainActor task;
            // without this synchronous gate it can create a new polling bridge
            // after the probe has already attempted to quiesce the old one.
            clipboardProbeOwnsTransport = true
            clipboardProbeChanged(.running)
            clipboardProbeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                // The continuous clipboard bridge is another legitimate
                // writer. Pause it while acceptance performs ordered native
                // and Agent round trips, otherwise a concurrent host
                // pasteboard change can overwrite the selection under test.
                let clipboardController = self.agentClipboardController
                await clipboardController?.quiesce()
                if self.agentClipboardController === clipboardController {
                    self.agentClipboardController = nil
                }
                defer {
                    self.clipboardProbeOwnsTransport = false
                    if let status = self.latestGuestStatus {
                        self.configureAgentClipboard(for: status)
                    }
                }
                do {
                    NSApp.activate(ignoringOtherApps: true)
                    if let machineView = self.machineView,
                       let window = machineView.window {
                        window.makeKeyAndOrderFront(nil)
                        window.makeFirstResponder(machineView)
                    }
                    let result = try await OmarchyClipboardAcceptanceProbe.run(
                        client: integrationClient,
                        sharedDirectory: layout.shared,
                        unlockCredential: OmarchyAcceptanceUnlockCredential(
                            environment: ProcessInfo.processInfo.environment
                        )
                    )
                    self.clipboardProbePassed = true
                    NSLog(
                        "Omarchy clipboard round trip passed (text %@/%@, PNG %@/%@)",
                        result.hostToGuestTextSHA256,
                        result.guestToHostTextSHA256,
                        result.hostToGuestImageSHA256,
                        result.guestToHostImageSHA256
                    )
                    self.clipboardProbeChanged(.passed(result))
                    self.startDynamicDisplayProbeIfNeeded(layout: layout)
                } catch {
                    NSLog("Omarchy clipboard round trip failed: %@", error.localizedDescription)
                    self.clipboardProbeChanged(.failed(error.localizedDescription))
                }
                self.clipboardProbeTask = nil
            }
        }

        private func startDynamicDisplayProbeIfNeeded(layout: VMOmarchyWorkspaceLayout) {
            guard ProcessInfo.processInfo.environment[
                OmarchyWorkspaceConfiguration.acceptanceEnabledKey
            ] == "1", clipboardProbePassed, !dynamicDisplayProbePassed,
                  dynamicDisplayProbeTask == nil, let integrationClient,
                  let machineView else { return }
            dynamicDisplayProbeChanged(.running)
            dynamicDisplayProbeTask = Task { @MainActor [weak self, weak machineView] in
                guard let self, let machineView else { return }
                do {
                    let result = try await OmarchyDynamicDisplayAcceptanceProbe.run(
                        client: integrationClient,
                        view: machineView,
                        sharedDirectory: layout.shared
                    )
                    self.dynamicDisplayProbePassed = true
                    NSLog(
                        "Omarchy dynamic display round trip passed (%dx%d -> %dx%d; host %dx%d)",
                        result.guestBefore.width, result.guestBefore.height,
                        result.guestAfter.width, result.guestAfter.height,
                        result.hostViewAfter.width, result.hostViewAfter.height
                    )
                    self.dynamicDisplayProbeChanged(.passed(result))
                    self.startAutomaticCommandSpaceProbeIfNeeded(self.latestGuestStatus)
                } catch {
                    NSLog("Omarchy dynamic display round trip failed: %@", error.localizedDescription)
                    self.dynamicDisplayProbeChanged(.failed(error.localizedDescription))
                }
                self.dynamicDisplayProbeTask = nil
            }
        }

        private func startAutomaticPauseResumeProbeIfNeeded() {
            guard ProcessInfo.processInfo.environment[
                OmarchyWorkspaceConfiguration.acceptanceEnabledKey
            ] == "1", dynamicDisplayProbePassed, !automaticPauseResumeProbeStarted else { return }
            automaticPauseResumeProbeStarted = true
            automaticRecoveryAfterResume = true
            pause(automaticResume: true)
        }

        @MainActor
        private func startAutomaticLockProbeIfNeeded() {
            let environment = ProcessInfo.processInfo.environment
            guard environment[OmarchyWorkspaceConfiguration.acceptanceEnabledKey] == "1" else {
                return
            }
            guard OmarchyAcceptanceUnlockCredential(environment: environment) != nil else {
                phaseChanged(.failed(
                    "Acceptance requires a printable ASCII unlock password of 1–128 bytes."
                ))
                return
            }
            guard automaticLockProbe.begin(), let integrationClient,
                  let credential = OmarchyAcceptanceUnlockCredential(environment: environment) else {
                return
            }
            Task { @MainActor [weak self, weak integrationClient] in
                do {
                    guard let self, let integrationClient else { return }
                    try await OmarchyInputDiagnosticsAcceptanceProbe.run(
                        client: integrationClient,
                        sharedDirectory: self.layout.shared,
                        diagnosticsDirectory: self.layout.diagnostics
                    )
                    NSApp.activate(ignoringOtherApps: true)
                    if let machineView = self.machineView,
                       let window = machineView.window {
                        window.makeKeyAndOrderFront(nil)
                        window.makeFirstResponder(machineView)
                    }
                    let cycle = try await OmarchyInputDiagnosticsAcceptanceProbe.runObservedLockCycle(
                        client: integrationClient,
                        sharedDirectory: self.layout.shared,
                        sendLockShortcut: { [weak self] in
                            // macOS virtual key 37 is L. Command is redirected
                            // to Guest Super by the production Accessibility
                            // bridge; Control remains part of the same chord.
                            self?.keyboardBridge?.runAcceptanceCommandChordProbe(
                                keyCode: 37,
                                additionalFlags: .maskControl
                            ) == true
                        },
                        sendUnlockSecret: { [weak self] in
                            self?.keyboardBridge?.runAcceptanceTextInput(
                                credential.password + "\n"
                            ) == true
                        }
                    )
                    guard self.automaticLockProbe.completeObservedCycle() else { return }
                    NSLog(
                        "Omarchy observed Guest lock/unlock cycle (%@ -> %@)",
                        cycle.lockedAt as NSDate,
                        cycle.unlockedAt as NSDate
                    )
                    OmarchyAcceptanceObservationReporter.reportLockCycleIfEnabled(
                        layout: self.layout,
                        lockedAt: cycle.lockedAt,
                        activeAt: cycle.unlockedAt
                    )
                    self.startAutomaticPauseResumeProbeIfNeeded()
                } catch {
                    self?.phaseChanged(.failed("Guest lock probe failed: \(error.localizedDescription)"))
                }
            }
        }

        @MainActor
        private func handleHostPowerEvent(_ event: VMOmarchyHostPowerEvent) {
            OmarchyAcceptanceObservationReporter.reportHostPowerEventIfEnabled(
                event == .willSleep ? .willSleep : .didWake,
                layout: layout
            )
            guard event == .didWake,
                  ProcessInfo.processInfo.environment[
                    OmarchyWorkspaceConfiguration.acceptanceEnabledKey
                  ] == "1" else { return }
            startHostWakeInteractiveProbe()
        }

        @MainActor
        private func startHostWakeInteractiveProbe() {
            hostWakeInteractiveTask?.cancel()
            hostWakeInteractiveTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    var client: VMOmarchyGuestAgentClient?
                    for _ in 0..<30 {
                        if let integrationClient = self.integrationClient,
                           self.latestGuestStatus != nil {
                            client = integrationClient
                            break
                        }
                        try await Task.sleep(for: .seconds(1))
                    }
                    guard let client else { throw CocoaError(.fileReadNoSuchFile) }
                    do {
                        try await OmarchyInputDiagnosticsAcceptanceProbe.verifyInteractiveDesktopEventually(
                            client: client,
                            sharedDirectory: self.layout.shared,
                            attempts: 2,
                            timeoutPerAttempt: .seconds(6)
                        )
                    } catch {
                        guard let credential = OmarchyAcceptanceUnlockCredential(
                            environment: ProcessInfo.processInfo.environment
                        ) else { throw error }
                        NSApp.activate(ignoringOtherApps: true)
                        if let machineView = self.machineView, let window = machineView.window {
                            window.makeKeyAndOrderFront(nil)
                            window.makeFirstResponder(machineView)
                        }
                        try await Task.sleep(for: .milliseconds(300))
                        guard self.keyboardBridge?.runAcceptanceTextInput(
                            credential.password + "\n"
                        ) == true else { throw CocoaError(.featureUnsupported) }
                        try await Task.sleep(for: OmarchyHostKeyboardTextEncoder.deliveryDuration(
                            for: credential.password + "\n"
                        ))
                        try await Task.sleep(for: .seconds(3))
                        try await OmarchyInputDiagnosticsAcceptanceProbe.verifyInteractiveDesktopEventually(
                            client: client,
                            sharedDirectory: self.layout.shared,
                            attempts: 3,
                            timeoutPerAttempt: .seconds(8)
                        )
                    }
                    guard let status = self.latestGuestStatus else {
                        throw CocoaError(.fileReadNoSuchFile)
                    }
                    OmarchyAcceptanceObservationReporter.reportInteractiveAfterHostWakeIfEnabled(
                        status: status,
                        layout: self.layout
                    )
                    NSLog("Omarchy interactive desktop recovered after host wake")
                } catch is CancellationError {
                    return
                } catch {
                    self.phaseChanged(.failed(
                        "Host wake interactive probe failed: \(error.localizedDescription)"
                    ))
                }
                self.hostWakeInteractiveTask = nil
            }
        }

        @MainActor
        private func handleAutomaticRecoveryReady(_ status: VMOmarchyGuestStatus) {
            switch automaticRecoveryStage {
            case .waitingForPostResumeReady:
                guard status.capabilities.contains("agent-restart-v1"),
                      !status.bootID.isEmpty,
                      status.agentInstanceID?.isEmpty == false,
                      let integrationClient else { return }
                recoveryBaselineStatus = status
                automaticRecoveryStage = .waitingForAgentDisconnect
                OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
                    .agentRestartRequested(status),
                    layout: layout
                )
                Task { @MainActor [weak self, weak integrationClient] in
                    do {
                        try await integrationClient?.requestAgentRestart()
                    } catch {
                        guard let self else { return }
                        self.automaticRecoveryStage = .idle
                        self.phaseChanged(.failed("Guest Agent restart probe failed: \(error.localizedDescription)"))
                    }
                }
            case .waitingForAgentReady:
                guard let baseline = recoveryBaselineStatus,
                      OmarchyAgentRestartRecoveryReadiness.isReady(
                        baseline: baseline,
                        recovered: status
                      ),
                      let integrationClient else { return }
                OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
                    .guestRestartRequested(status),
                    layout: layout
                )
                recoveryBaselineStatus = status
                guard guestRestartAcceptanceState.begin(previousBootID: status.bootID) else {
                    automaticRecoveryStage = .idle
                    phaseChanged(.failed("Guest restart probe could not establish its boot baseline."))
                    return
                }
                automaticRecoveryStage = .waitingForGuestDisconnect
                integrationClient.requestRestart()
            case .waitingForGuestReady:
                switch guestRestartAcceptanceState.observe(status) {
                case .none:
                    break
                case .recoverInteractiveDesktop:
                    recoverGuestRestartInteractiveDesktop()
                }
            case .idle, .waitingForAgentDisconnect, .waitingForGuestDisconnect, .complete:
                break
            }
            startAutomaticFullScreenProbeIfNeeded(status)
        }

        @MainActor
        private func recoverGuestRestartInteractiveDesktop() {
            guard let credential = OmarchyAcceptanceUnlockCredential(
                environment: ProcessInfo.processInfo.environment
            ), let integrationClient, keyboardBridge != nil else {
                automaticRecoveryStage = .idle
                phaseChanged(.failed("The Guest restart unlock credential became unavailable."))
                return
            }
            guestRestartUnlockTimeoutTask?.cancel()
            guestRestartUnlockTimeoutTask = Task { @MainActor [weak self, weak integrationClient] in
                do {
                    guard let self, let integrationClient else { return }
                    do {
                        // A reboot may return directly to an already unlocked
                        // desktop. Prove that path before typing a credential;
                        // otherwise the password would leak into an application.
                        try await OmarchyInputDiagnosticsAcceptanceProbe.verifyInteractiveDesktopEventually(
                            client: integrationClient,
                            sharedDirectory: self.layout.shared,
                            attempts: 2,
                            timeoutPerAttempt: .seconds(6)
                        )
                    } catch {
                        NSApp.activate(ignoringOtherApps: true)
                        if let machineView = self.machineView, let window = machineView.window {
                            window.makeKeyAndOrderFront(nil)
                            window.makeFirstResponder(machineView)
                        }
                        try await Task.sleep(for: .milliseconds(300))
                        guard self.keyboardBridge?.runAcceptanceTextInput(
                            credential.password + "\n"
                        ) == true else {
                            throw CocoaError(.featureUnsupported)
                        }
                        try await Task.sleep(for: OmarchyHostKeyboardTextEncoder.deliveryDuration(
                            for: credential.password + "\n"
                        ))
                        try await Task.sleep(for: .seconds(3))
                        try await OmarchyInputDiagnosticsAcceptanceProbe.verifyInteractiveDesktopEventually(
                            client: integrationClient,
                            sharedDirectory: self.layout.shared,
                            attempts: 3,
                            timeoutPerAttempt: .seconds(8)
                        )
                    }
                    guard let status = self.latestGuestStatus,
                          self.guestRestartAcceptanceState.completeInteractiveProof(
                            bootID: status.bootID
                          ) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
                        .guestInteractiveAfterRestart(status),
                        layout: self.layout
                    )
                    self.guestRestartUnlockTimeoutTask = nil
                    self.automaticRecoveryStage = .complete
                    self.recoveryBaselineStatus = nil
                    self.startAutomaticFullScreenProbeIfNeeded(status)
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else { return }
                    self.automaticRecoveryStage = .idle
                    self.phaseChanged(.failed(
                        "Guest restart unlock probe failed: \(error.localizedDescription)"
                    ))
                }
            }
        }

        @MainActor
        private func startAutomaticFullScreenProbeIfNeeded(_ status: VMOmarchyGuestStatus) {
            guard ProcessInfo.processInfo.environment[
                OmarchyWorkspaceConfiguration.acceptanceEnabledKey
            ] == "1", status.desktopSessionActive, !status.provisioningPending,
                  automaticRecoveryStage == .complete,
                  !automaticFullScreenProbeStarted, let machineView,
                  let window = machineView.window else { return }
            automaticFullScreenProbeStarted = true
            let probe = OmarchyFullScreenAcceptanceProbe(
                window: window,
                virtualMachineView: machineView,
                layout: layout
            )
            fullScreenProbe = probe
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak probe] in
                probe?.start()
            }
        }

        @MainActor
        private func startAutomaticCommandSpaceProbeIfNeeded(_ status: VMOmarchyGuestStatus?) {
            guard ProcessInfo.processInfo.environment[
                OmarchyWorkspaceConfiguration.acceptanceEnabledKey
            ] == "1", let status, status.desktopSessionActive, !status.provisioningPending,
                  !automaticCommandSpaceProbeStarted else { return }
            guard keyboardBridge?.runAcceptanceCommandSpaceProbe() == true,
                  let integrationClient else {
                phaseChanged(.failed(
                    "Focused Command+Space acceptance could not reach the Accessibility event tap."
                ))
                return
            }
            automaticCommandSpaceProbeStarted = true
            Task { @MainActor [weak self, weak integrationClient] in
                do {
                    // Command+Space intentionally opens Omarchy Menu. Keep it
                    // visible long enough for the event-tap observation to be
                    // committed, then dismiss it before the lock probe begins.
                    // Otherwise the next acceptance chord and typed secret can
                    // land in the menu's search field instead of the desktop.
                    try await Task.sleep(for: .seconds(1))
                    try await integrationClient?.injectKeyChord(modifiers: [], key: 1)
                    try await Task.sleep(for: .milliseconds(500))
                    self?.startAutomaticLockProbeIfNeeded()
                } catch {
                    self?.phaseChanged(.failed(
                        "Focused Command+Space cleanup failed: \(error.localizedDescription)"
                    ))
                }
            }
        }

        @MainActor
        private func handleAutomaticRecoveryDisconnect() {
            switch automaticRecoveryStage {
            case .waitingForAgentDisconnect:
                OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
                    .disconnectedAfterAgentRestart,
                    layout: layout
                )
                automaticRecoveryStage = .waitingForAgentReady
            case .waitingForGuestDisconnect:
                OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
                    .disconnectedAfterGuestRestart,
                    layout: layout
                )
                automaticRecoveryStage = .waitingForGuestReady
            case .idle, .waitingForPostResumeReady, .waitingForAgentReady,
                 .waitingForGuestReady, .complete:
                break
            }
        }

        private func requestStop() {
            guard let machine else { return }
            guard machine.canRequestStop else {
                phaseChanged(.failed("Omarchy cannot accept a graceful stop request right now."))
                return
            }
            do {
                try machine.requestStop()
            } catch {
                phaseChanged(.failed(error.localizedDescription))
            }
        }

        private func pause(automaticResume: Bool) {
            guard let machine, machine.canPause else {
                phaseChanged(.failed("Omarchy cannot be paused right now."))
                return
            }
            OmarchyAcceptanceObservationReporter.reportVirtualMachineEventIfEnabled(
                .pauseRequested,
                layout: layout
            )
            machine.pause { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success:
                        OmarchyAcceptanceObservationReporter.reportVirtualMachineEventIfEnabled(
                            .paused,
                            layout: self.layout
                        )
                        self.keyboardBridge?.stop()
                        self.stopAgentClipboard()
                        self.stopNotifications()
                        self.integrationClient?.virtualMachineDidPause()
                        self.phaseChanged(.paused)
                        if automaticResume {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                                self?.resume()
                            }
                        }
                    case .failure(let error):
                        self.automaticPauseResumeProbeStarted = false
                        self.phaseChanged(.failed(error.localizedDescription))
                    }
                }
            }
        }

        private func resume() {
            guard let machine, machine.canResume else {
                phaseChanged(.failed("Omarchy cannot be resumed right now."))
                return
            }
            machine.resume { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success:
                        OmarchyAcceptanceObservationReporter.reportVirtualMachineEventIfEnabled(
                            .resumed,
                            layout: self.layout
                        )
                        if self.automaticRecoveryAfterResume {
                            self.automaticRecoveryAfterResume = false
                            self.automaticRecoveryStage = .waitingForPostResumeReady
                        }
                        self.integrationClient?.virtualMachineDidResume()
                        self.keyboardBridge?.start()
                        self.phaseChanged(.running)
                    case .failure(let error):
                        self.automaticPauseResumeProbeStarted = false
                        self.phaseChanged(.failed(error.localizedDescription))
                    }
                }
            }
        }

        private func forceStop() {
            guard let machine, machine.canStop else {
                phaseChanged(.failed("Omarchy could not be stopped after the graceful shutdown timed out."))
                return
            }
            machine.stop { [weak self, weak machine] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        self.phaseChanged(.failed(error.localizedDescription))
                    } else if self.machine === machine {
                        self.stopIntegration()
                        self.machine = nil
                        self.phaseChanged(.stopped)
                    }
                }
            }
        }

        func stopImmediately() {
            sharedFolderProbeTask?.cancel()
            sharedFolderProbeTask = nil
            clipboardProbeTask?.cancel()
            clipboardProbeTask = nil
            dynamicDisplayProbeTask?.cancel()
            dynamicDisplayProbeTask = nil
            keyboardBridge?.stop()
            keyboardBridge = nil
            stopIntegration()
            guard let machine else { return }
            Task { @MainActor in
                OmarchyApplicationTerminationController.shared.stopForViewTeardown(machine)
            }
            self.machine = nil
        }

        func guestDidStop(_ virtualMachine: VZVirtualMachine) {
            Task { @MainActor in
                OmarchyApplicationTerminationController.shared.machineDidStop(virtualMachine)
            }
            stopIntegration()
            machine = nil
            phaseChanged(.stopped)
        }

        func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
            Task { @MainActor in
                OmarchyApplicationTerminationController.shared.machineDidStop(virtualMachine)
            }
            stopIntegration()
            phaseChanged(.failed(error.localizedDescription))
        }

        private func stopIntegration() {
            let clipboardController = agentClipboardController
            agentClipboardController = nil
            Task { @MainActor in clipboardController?.stop() }
            let notifications = notificationController
            notificationController = nil
            Task { @MainActor in notifications?.stop() }
            sharedFolderProbeTask?.cancel()
            sharedFolderProbeTask = nil
            sharedFolderProbePassed = false
            clipboardProbeTask?.cancel()
            clipboardProbeTask = nil
            clipboardProbePassed = false
            dynamicDisplayProbeTask?.cancel()
            dynamicDisplayProbeTask = nil
            dynamicDisplayProbePassed = false
            let client = integrationClient
            integrationClient = nil
            Task { @MainActor in client?.stop() }
        }
    }
}

private extension Notification.Name {
    static let omarchyRequestStop = Notification.Name("EZVMOmarchy.requestStop")
    static let omarchyRequestPause = Notification.Name("EZVMOmarchy.requestPause")
    static let omarchyRequestResume = Notification.Name("EZVMOmarchy.requestResume")
    static let omarchyRequestKeyboardPermission = Notification.Name("EZVMOmarchy.requestKeyboardPermission")
    static let omarchyForceStop = Notification.Name("EZVMOmarchy.forceStop")
}
