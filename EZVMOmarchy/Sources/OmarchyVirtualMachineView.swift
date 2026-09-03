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
                phaseChanged: handlePhaseChange
            )
            .id(sessionID)
            if phase != .running {
                statusOverlay
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
                    Button("Restart Omarchy", systemImage: "arrow.clockwise") {
                        handle(.restartRequested)
                    }
                    Button("Stop Omarchy", systemImage: "stop.fill") {
                        handle(.stopRequested)
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
                if status.capabilities.contains("clipboard-text-v1") {
                    Text(status.capabilities.contains("clipboard-image-v1")
                        ? "Text and image clipboard ready"
                        : "Text clipboard ready")
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
        OmarchyAcceptanceObservationReporter.reportIfEnabled(
            status: status,
            requiredCapabilities: profile.requiredGuestCapabilities,
            layout: layout,
            sharedFolderRoundTrip: sharedFolderRoundTrip,
            clipboardRoundTrip: clipboardRoundTrip
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
            clipboardRoundTrip: clipboardRoundTrip
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
            clipboardRoundTrip: clipboardRoundTrip
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
        case .stopped:
            handle(.machineStopped)
            refreshRecoveryPoints()
        case .failed(let message): handle(.machineFailed(message))
        case .starting, .stopping: break
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
        case startRequested
        case stopRequested
        case restartRequested
        case machineStopped
        case machineFailed(String)
        case stopTimedOut
    }

    enum Effect: Equatable {
        case requestStop
        case startNewSession
        case scheduleForceStop
        case cancelForceStop
        case forceStop
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .machineStarted:
            phase = .running
        case .startRequested:
            guard phase == .stopped || isFailed else { return [] }
            restartAfterStop = false
            phase = .starting
            return [.startNewSession]
        case .stopRequested:
            guard phase == .running else { return [] }
            restartAfterStop = false
            phase = .stopping
            return [.requestStop, .scheduleForceStop]
        case .restartRequested:
            guard phase == .running else { return [] }
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
    let phaseChanged: (OmarchyVirtualMachineView.Phase) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionID: sessionID,
            keyboardIntegrationChanged: keyboardIntegrationChanged,
            integrationChanged: integrationChanged,
            sharedFolderProbeChanged: sharedFolderProbeChanged,
            clipboardProbeChanged: clipboardProbeChanged,
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

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {}

    static func dismantleNSView(_ nsView: VZVirtualMachineView, coordinator: Coordinator) {
        coordinator.stopImmediately()
        nsView.virtualMachine = nil
    }

    final class Coordinator: NSObject, VZVirtualMachineDelegate {
        var machine: VZVirtualMachine?
        let sessionID: UUID
        let keyboardIntegrationChanged: (OmarchyKeyboardIntegrationState) -> Void
        let integrationChanged: (VMOmarchyIntegrationState) -> Void
        let sharedFolderProbeChanged: (VMOmarchySharedFolderProbeState) -> Void
        let clipboardProbeChanged: (OmarchyClipboardProbeState) -> Void
        let phaseChanged: (OmarchyVirtualMachineView.Phase) -> Void
        private var stopObserver: NSObjectProtocol?
        private var keyboardPermissionObserver: NSObjectProtocol?
        private var forceStopObserver: NSObjectProtocol?
        private var keyboardBridge: OmarchyFocusedCommandBridge?
        private var integrationClient: VMOmarchyGuestAgentClient?
        private var sharedFolderProbeTask: Task<Void, Never>?
        private var sharedFolderProbePassed = false
        private var clipboardProbeTask: Task<Void, Never>?
        private var clipboardProbePassed = false

        init(
            sessionID: UUID,
            keyboardIntegrationChanged: @escaping (OmarchyKeyboardIntegrationState) -> Void,
            integrationChanged: @escaping (VMOmarchyIntegrationState) -> Void,
            sharedFolderProbeChanged: @escaping (VMOmarchySharedFolderProbeState) -> Void,
            clipboardProbeChanged: @escaping (OmarchyClipboardProbeState) -> Void,
            phaseChanged: @escaping (OmarchyVirtualMachineView.Phase) -> Void
        ) {
            self.sessionID = sessionID
            self.keyboardIntegrationChanged = keyboardIntegrationChanged
            self.integrationChanged = integrationChanged
            self.sharedFolderProbeChanged = sharedFolderProbeChanged
            self.clipboardProbeChanged = clipboardProbeChanged
            self.phaseChanged = phaseChanged
        }

        deinit {
            if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) }
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
                stateChanged: keyboardIntegrationChanged
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
                        stateChanged: { [weak self] state in
                            guard let self else { return }
                            self.integrationChanged(state)
                            if case .ready = state {
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
                        hostDirectory: layout.shared
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
                do {
                    let result = try await OmarchyClipboardAcceptanceProbe.run(
                        client: integrationClient,
                        sharedDirectory: layout.shared
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
                } catch {
                    NSLog("Omarchy clipboard round trip failed: %@", error.localizedDescription)
                    self.clipboardProbeChanged(.failed(error.localizedDescription))
                }
                self.clipboardProbeTask = nil
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

        private func forceStop() {
            guard let machine, machine.canStop else {
                phaseChanged(.failed("Omarchy could not be stopped after the graceful shutdown timed out."))
                return
            }
            machine.stop { [weak self] error in
                if let error {
                    DispatchQueue.main.async { self?.phaseChanged(.failed(error.localizedDescription)) }
                }
            }
        }

        func stopImmediately() {
            sharedFolderProbeTask?.cancel()
            sharedFolderProbeTask = nil
            clipboardProbeTask?.cancel()
            clipboardProbeTask = nil
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
            sharedFolderProbeTask?.cancel()
            sharedFolderProbeTask = nil
            sharedFolderProbePassed = false
            clipboardProbeTask?.cancel()
            clipboardProbeTask = nil
            clipboardProbePassed = false
            let client = integrationClient
            integrationClient = nil
            Task { @MainActor in client?.stop() }
        }
    }
}

private extension Notification.Name {
    static let omarchyRequestStop = Notification.Name("EZVMOmarchy.requestStop")
    static let omarchyRequestKeyboardPermission = Notification.Name("EZVMOmarchy.requestKeyboardPermission")
    static let omarchyForceStop = Notification.Name("EZVMOmarchy.forceStop")
}
