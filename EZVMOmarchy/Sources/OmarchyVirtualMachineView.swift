import EZVMCore
import SwiftUI
import Virtualization

struct OmarchyVirtualMachineView: View {
    let layout: VMOmarchyWorkspaceLayout
    let profile: VMOmarchyProfile
    @State private var lifecycle = OmarchyMachineLifecycle()
    @State private var sessionID = UUID()
    @State private var keyboardIntegration: OmarchyKeyboardIntegrationState = .accessibilityRequired
    @State private var integration: VMOmarchyIntegrationState = .connecting
    @State private var stopTimeoutTask: Task<Void, Never>?

    private var phase: Phase { lifecycle.phase }

    var body: some View {
        ZStack {
            OmarchyVirtualMachineRepresentable(
                layout: layout,
                profile: profile,
                sessionID: sessionID,
                keyboardIntegrationChanged: { keyboardIntegration = $0 },
                integrationChanged: { integration = $0 },
                phaseChanged: handlePhaseChange
            )
            .id(sessionID)
            if phase != .running {
                statusOverlay
            }
        }
        .background(.black)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                integrationMenu
                Button("Open Shared Folder", systemImage: "folder") {
                    NSWorkspace.shared.open(layout.shared)
                }
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
                Text("Capabilities: \(status.capabilities.sorted().joined(separator: ", "))")
            }
        } label: {
            Label("Integration", systemImage: integrationReady ? "checkmark.circle.fill" : "exclamationmark.circle")
        }
        .help(integrationReady ? "Omarchy integration is ready" : "Omarchy integration is not ready")
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
        case .stopped: handle(.machineStopped)
        case .failed(let message): handle(.machineFailed(message))
        case .starting, .stopping: break
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
    let phaseChanged: (OmarchyVirtualMachineView.Phase) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionID: sessionID,
            keyboardIntegrationChanged: keyboardIntegrationChanged,
            integrationChanged: integrationChanged,
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
        let phaseChanged: (OmarchyVirtualMachineView.Phase) -> Void
        private var stopObserver: NSObjectProtocol?
        private var keyboardPermissionObserver: NSObjectProtocol?
        private var forceStopObserver: NSObjectProtocol?
        private var keyboardBridge: OmarchyFocusedCommandBridge?
        private var integrationClient: VMOmarchyGuestAgentClient?

        init(
            sessionID: UUID,
            keyboardIntegrationChanged: @escaping (OmarchyKeyboardIntegrationState) -> Void,
            integrationChanged: @escaping (VMOmarchyIntegrationState) -> Void,
            phaseChanged: @escaping (OmarchyVirtualMachineView.Phase) -> Void
        ) {
            self.sessionID = sessionID
            self.keyboardIntegrationChanged = keyboardIntegrationChanged
            self.integrationChanged = integrationChanged
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
                        stateChanged: self.integrationChanged
                    )
                    self.integrationClient = client
                    client.start()
                } catch {
                    self.integrationChanged(.disconnected(error.localizedDescription))
                }
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
            keyboardBridge?.stop()
            keyboardBridge = nil
            stopIntegration()
            guard let machine, machine.canStop else { return }
            machine.stop { _ in }
            self.machine = nil
        }

        func guestDidStop(_ virtualMachine: VZVirtualMachine) {
            stopIntegration()
            machine = nil
            phaseChanged(.stopped)
        }

        func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
            stopIntegration()
            phaseChanged(.failed(error.localizedDescription))
        }

        private func stopIntegration() {
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
