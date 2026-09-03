import EZVMCore
import SwiftUI
import Virtualization

struct OmarchyVirtualMachineView: View {
    let layout: VMOmarchyWorkspaceLayout
    let profile: VMOmarchyProfile
    @State private var lifecycle = OmarchyMachineLifecycle()
    @State private var sessionID = UUID()
    @State private var keyboardIntegration: OmarchyKeyboardIntegrationState = .accessibilityRequired

    private var phase: Phase { lifecycle.phase }

    var body: some View {
        ZStack {
            OmarchyVirtualMachineRepresentable(
                layout: layout,
                profile: profile,
                sessionID: sessionID,
                keyboardIntegrationChanged: { keyboardIntegration = $0 },
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
    }

    enum Effect: Equatable {
        case requestStop
        case startNewSession
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
            return [.requestStop]
        case .restartRequested:
            guard phase == .running else { return [] }
            restartAfterStop = true
            phase = .stopping
            return [.requestStop]
        case .machineStopped:
            if restartAfterStop {
                restartAfterStop = false
                phase = .starting
                return [.startNewSession]
            }
            phase = .stopped
        case .machineFailed(let message):
            restartAfterStop = false
            phase = .failed(message)
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
    let phaseChanged: (OmarchyVirtualMachineView.Phase) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionID: sessionID,
            keyboardIntegrationChanged: keyboardIntegrationChanged,
            phaseChanged: phaseChanged
        )
    }

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
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
                    case .success: context.coordinator.phaseChanged(.running)
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
        let phaseChanged: (OmarchyVirtualMachineView.Phase) -> Void
        private var stopObserver: NSObjectProtocol?
        private var keyboardPermissionObserver: NSObjectProtocol?
        private var keyboardBridge: OmarchyFocusedCommandBridge?

        init(
            sessionID: UUID,
            keyboardIntegrationChanged: @escaping (OmarchyKeyboardIntegrationState) -> Void,
            phaseChanged: @escaping (OmarchyVirtualMachineView.Phase) -> Void
        ) {
            self.sessionID = sessionID
            self.keyboardIntegrationChanged = keyboardIntegrationChanged
            self.phaseChanged = phaseChanged
        }

        deinit {
            if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) }
            if let keyboardPermissionObserver { NotificationCenter.default.removeObserver(keyboardPermissionObserver) }
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

        func stopImmediately() {
            keyboardBridge?.stop()
            keyboardBridge = nil
            guard let machine, machine.canStop else { return }
            machine.stop { _ in }
            self.machine = nil
        }

        func guestDidStop(_ virtualMachine: VZVirtualMachine) {
            machine = nil
            phaseChanged(.stopped)
        }

        func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
            phaseChanged(.failed(error.localizedDescription))
        }
    }
}

private extension Notification.Name {
    static let omarchyRequestStop = Notification.Name("EZVMOmarchy.requestStop")
    static let omarchyRequestKeyboardPermission = Notification.Name("EZVMOmarchy.requestKeyboardPermission")
}
