import EZVMCore
import SwiftUI
import UniformTypeIdentifiers
import Virtualization

private let omarchyMetadataQueue = DispatchQueue(label: "com.everettjf.ezvm.omarchy.metadata")

struct OmarchyVirtualMachineView: View {
    let layout: VMOmarchyWorkspaceLayout
    let profile: VMOmarchyProfile
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
            if keyboardIntegration == .accessibilityRequired {
                HStack {
                    Text("Allow Accessibility access so Command shortcuts stay inside Omarchy.")
                    Spacer()
                    Button("Enable") {
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
                if status.capabilities.contains("clipboard-agent-text-v1") {
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
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: status,
            layout: layout
        )
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
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        do {
            let configuration = try VMOmarchyVirtualMachineBuilder.makeConfiguration(
                layout: layout,
                profile: profile
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
                self.keyboardBridge?.requestPermission()
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
                            OmarchyAcceptanceObservationReporter.reportHostPowerEventIfEnabled(
                                event == .willSleep ? .willSleep : .didWake,
                                layout: self.layout
                            )
                        },
                        stateChanged: { [weak self] state in
                            guard let self else { return }
                            self.integrationChanged(state)
                            switch state {
                            case .ready(let status):
                                Task { @MainActor [weak self] in
                                    self?.configureAgentClipboard(for: status)
                                    self?.handleAutomaticRecoveryReady(status)
                                    self?.refreshOwnerProvisioningProgressIfNeeded(status)
                                }
                            case .disconnected:
                                Task { @MainActor [weak self] in
                                    self?.stopAgentClipboard()
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
            let required = Set(["clipboard-agent-text-v1", "clipboard-agent-image-v1"])
            guard required.isSubset(of: Set(status.capabilities)),
                  status.desktopSessionActive, !status.provisioningPending,
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
        private func stopAgentClipboard() {
            agentClipboardController?.stop()
            agentClipboardController = nil
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
            clipboardProbeChanged(.running)
            clipboardProbeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                // The continuous clipboard bridge is another legitimate
                // writer. Pause it while acceptance performs ordered native
                // and Agent round trips, otherwise a concurrent host
                // pasteboard change can overwrite the selection under test.
                let clipboardController = self.agentClipboardController
                clipboardController?.stop()
                defer { clipboardController?.start() }
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
                    self.startAutomaticLockProbeIfNeeded()
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
            guard automaticLockProbe.begin(), let integrationClient else { return }
            Task { @MainActor [weak self, weak integrationClient] in
                do {
                    // Omarchy's default lock binding is Super+Control+L.
                    try await integrationClient?.injectKeyChord(modifiers: [125, 29], key: 38)
                } catch {
                    self?.phaseChanged(.failed("Guest lock probe failed: \(error.localizedDescription)"))
                }
            }
        }

        @MainActor
        private func handleAutomaticRecoveryReady(_ status: VMOmarchyGuestStatus) {
            startAutomaticCommandSpaceProbeIfNeeded(status)
            handleAutomaticLockProbeReady(status)
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
                      status.bootID == baseline.bootID,
                      let instanceID = status.agentInstanceID,
                      instanceID != baseline.agentInstanceID,
                      let integrationClient else { return }
                OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
                    .guestRestartRequested(status),
                    layout: layout
                )
                recoveryBaselineStatus = status
                automaticRecoveryStage = .waitingForGuestDisconnect
                integrationClient.requestRestart()
            case .waitingForGuestReady:
                guard let baseline = recoveryBaselineStatus,
                      !status.bootID.isEmpty,
                      status.bootID != baseline.bootID else { return }
                automaticRecoveryStage = .complete
                recoveryBaselineStatus = nil
            case .idle, .waitingForAgentDisconnect, .waitingForGuestDisconnect, .complete:
                break
            }
            startAutomaticFullScreenProbeIfNeeded(status)
        }

        @MainActor
        private func handleAutomaticLockProbeReady(_ status: VMOmarchyGuestStatus) {
            switch automaticLockProbe.observe(status) {
            case .none:
                break
            case .submitUnlockSecret:
                guard let credential = OmarchyAcceptanceUnlockCredential(
                    environment: ProcessInfo.processInfo.environment
                ), let integrationClient else {
                    phaseChanged(.failed("The acceptance unlock credential became unavailable."))
                    return
                }
                Task { @MainActor [weak self, weak integrationClient] in
                    do {
                        try await integrationClient?.typeUSASCII(credential.password)
                        try await integrationClient?.injectKeyChord(modifiers: [], key: 28)
                    } catch {
                        self?.phaseChanged(.failed("Guest unlock probe failed: \(error.localizedDescription)"))
                    }
                }
            case .completed:
                startAutomaticPauseResumeProbeIfNeeded()
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
        private func startAutomaticCommandSpaceProbeIfNeeded(_ status: VMOmarchyGuestStatus) {
            guard ProcessInfo.processInfo.environment[
                OmarchyWorkspaceConfiguration.acceptanceEnabledKey
            ] == "1", status.desktopSessionActive, !status.provisioningPending,
                  !automaticCommandSpaceProbeStarted,
                  keyboardBridge?.runAcceptanceCommandSpaceProbe() == true else { return }
            automaticCommandSpaceProbeStarted = true
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
