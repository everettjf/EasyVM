import AppKit
import EZVMCore
import Foundation

struct OmarchyFullScreenTransitionState: Equatable {
    private(set) var enteredAt: Date?
    private(set) var exitedAt: Date?

    mutating func observeEntered(at date: Date) -> Bool {
        guard enteredAt == nil, exitedAt == nil else { return false }
        enteredAt = date
        return true
    }

    mutating func observeExited(at date: Date) -> Bool {
        guard enteredAt != nil, exitedAt == nil else { return false }
        exitedAt = date
        return true
    }
}

@MainActor
final class OmarchyFullScreenAcceptanceProbe {
    private weak var window: NSWindow?
    private weak var virtualMachineView: NSView?
    private let layout: VMOmarchyWorkspaceLayout
    private var state = OmarchyFullScreenTransitionState()
    private var observers: [NSObjectProtocol] = []
    private var timeoutTask: Task<Void, Never>?

    init(window: NSWindow, virtualMachineView: NSView, layout: VMOmarchyWorkspaceLayout) {
        self.window = window
        self.virtualMachineView = virtualMachineView
        self.layout = layout
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        timeoutTask?.cancel()
    }

    func start() {
        guard observers.isEmpty, let window, !window.styleMask.contains(.fullScreen) else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.didEnterFullScreen() }
            },
            center.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.didExitFullScreen() }
            }
        ]
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            NSLog("Omarchy full-screen acceptance timed out before a complete enter/exit cycle")
            self?.stop()
        }
        NSLog("Omarchy full-screen acceptance requesting entry")
        window.toggleFullScreen(nil)
    }

    private func didEnterFullScreen() {
        guard state.observeEntered(at: Date()), let window else { return }
        NSLog("Omarchy full-screen acceptance observed entry")
        // AppKit can ignore a second synchronous toggle while it is still
        // unwinding didEnterFullScreen. Schedule the exit on a later run-loop
        // turn so the acceptance probe cannot strand the App in its new Space.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak window] in
            NSLog("Omarchy full-screen acceptance requesting exit")
            window?.toggleFullScreen(nil)
        }
    }

    private func didExitFullScreen() {
        guard state.observeExited(at: Date()), let window else { return }
        NSLog("Omarchy full-screen acceptance observed exit")
        if let virtualMachineView {
            window.makeFirstResponder(virtualMachineView)
        }
        OmarchyAcceptanceObservationReporter.reportFullScreenIfEnabled(
            layout: layout,
            enteredAt: state.enteredAt,
            exitedAt: state.exitedAt,
            applicationActive: NSApp.isActive,
            virtualMachineWindowKey: window.isKeyWindow,
            virtualMachineViewFocused: window.firstResponder === virtualMachineView
        )
        stop()
    }

    private func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        timeoutTask?.cancel()
        timeoutTask = nil
    }
}
