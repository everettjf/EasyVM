//
//  VMOSInternalView.swift
//  EZVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI
import Observation

#if arch(arm64)
enum VMGuestAgentTransferDirection: Equatable {
    case upload
    case download
}

enum VMGuestAgentTransferState: Equatable {
    case idle
    case preparing(name: String)
    case transferring(direction: VMGuestAgentTransferDirection, name: String, completedBytes: UInt64, totalBytes: UInt64)
    case completed(String)
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .preparing, .transferring: true
        default: false
        }
    }
}

@MainActor
@Observable
final class VMRuntimeState {
    typealias Phase = VMRuntimePhase

    private(set) var phase: Phase = .preparing
    private(set) var balloonMemoryTarget: UInt64?
    private(set) var balloonMemoryMaximum: UInt64?
    private(set) var guestAgentState: VMGuestAgentConnectionState = .unavailable
    private(set) var guestAgentTransferState: VMGuestAgentTransferState = .idle
    private(set) var graphicsBackendKind: VMGraphicsBackendKind?
    private(set) var graphicsBackendDetail: String?
    @ObservationIgnored
    weak var controller: VMOSInternalVirtualMachineViewController?

    var errorMessage: String? {
        guard case let .failed(message) = phase else { return nil }
        return message
    }

    var canPause: Bool { phase == .running }
    var canResume: Bool { phase == .paused }
    var canRequestStop: Bool { phase == .running || phase == .paused }
    var canSave: Bool { phase == .running || phase == .paused }
    var canForceStop: Bool {
        switch phase {
        case .starting, .restoring, .running, .pausing, .paused, .saving, .stopping: true
        default: false
        }
    }
    var canManageBalloon: Bool {
        balloonMemoryMaximum != nil && (phase == .running || phase == .paused)
    }

    var needsCloseConfirmation: Bool {
        switch phase {
        case .starting, .restoring, .running, .pausing, .paused:
            true
        default:
            false
        }
    }

    var isCloseInProgress: Bool {
        phase == .saving || phase == .stopping
    }

    func update(_ phase: Phase) {
        self.phase = phase
    }

    func updateBalloonMemory(target: UInt64?, maximum: UInt64?) {
        balloonMemoryTarget = target
        balloonMemoryMaximum = maximum
    }

    func updateGuestAgent(_ state: VMGuestAgentConnectionState) {
        guestAgentState = state
    }

    func updateGuestAgentTransfer(_ state: VMGuestAgentTransferState) {
        guestAgentTransferState = state
    }

    func updateGraphicsBackend(kind: VMGraphicsBackendKind, detail: String?) {
        graphicsBackendKind = kind
        graphicsBackendDetail = detail
    }

    func pause() { controller?.pauseMachine() }
    func resume() { controller?.resumeMachine() }
    func requestStop() { controller?.requestStopMachine() }
    func saveAndStop() { controller?.saveAndStopMachine() }
    func saveAndStopForWindowClose() { controller?.saveAndStopForWindowClose() }
    func forceStop() { controller?.forceStopMachine() }
    func useCurrentDisplayAsThumbnail() { controller?.useCurrentDisplayAsThumbnail() }
    func setBalloonMemory(fraction: Double) { controller?.setBalloonMemory(fraction: fraction) }
    func guestAgentShutdown() { controller?.sendGuestAgentCommand(.shutdown) }
    func guestAgentRestart() { controller?.sendGuestAgentCommand(.restart) }
    func guestAgentUpload(localURL: URL, destinationPath: String, overwrite: Bool) {
        controller?.uploadToGuest(localURL: localURL, destinationPath: destinationPath, overwrite: overwrite)
    }
    func guestAgentDownload(sourcePath: String, destinationURL: URL) {
        controller?.downloadFromGuest(sourcePath: sourcePath, destinationURL: destinationURL)
    }
    func cancelGuestAgentTransfer() { controller?.cancelGuestAgentTransfer() }
}

struct VMWindowCloseObserver: NSViewRepresentable {
    let rootPath: URL
    let shouldConfirm: () -> Bool
    let shouldBlock: () -> Bool
    let onCloseAttempt: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(rootPath: rootPath, shouldConfirm: shouldConfirm, shouldBlock: shouldBlock, onCloseAttempt: onCloseAttempt)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.rootPath = rootPath
        context.coordinator.shouldConfirm = shouldConfirm
        context.coordinator.shouldBlock = shouldBlock
        context.coordinator.onCloseAttempt = onCloseAttempt
        DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var rootPath: URL
        var shouldConfirm: () -> Bool
        var shouldBlock: () -> Bool
        var onCloseAttempt: () -> Void
        private weak var window: NSWindow?
        private var previousDelegate: NSWindowDelegate?

        init(rootPath: URL, shouldConfirm: @escaping () -> Bool, shouldBlock: @escaping () -> Bool, onCloseAttempt: @escaping () -> Void) {
            self.rootPath = rootPath
            self.shouldConfirm = shouldConfirm
            self.shouldBlock = shouldBlock
            self.onCloseAttempt = onCloseAttempt
        }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            window.representedURL = rootPath.standardizedFileURL
            guard self.window !== window else { return }
            detach()
            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
        }

        func detach() {
            if window?.delegate === self {
                window?.delegate = previousDelegate
            }
            window = nil
            previousDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if shouldBlock() { return false }
            guard shouldConfirm() else {
                return previousDelegate?.windowShouldClose?(sender) ?? true
            }
            onCloseAttempt()
            return false
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (previousDelegate?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if previousDelegate?.responds(to: aSelector) == true { return previousDelegate }
            return super.forwardingTarget(for: aSelector)
        }
    }
}

struct VMOSInternalVirtualMachineView : NSViewControllerRepresentable {
    let rootPath: URL
    let recoveryMode: Bool
    var runtimeState: VMRuntimeState
    
    class Coordinator : NSObject {
        var parent: VMOSInternalVirtualMachineView
        
        init(_ parent: VMOSInternalVirtualMachineView) {
            self.parent = parent
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSViewController(context: Context) -> VMOSInternalVirtualMachineViewController {
        let vc = VMOSInternalVirtualMachineViewController()
        vc.rootPath = rootPath
        vc.recoveryMode = recoveryMode
        vc.runtimeState = runtimeState
        runtimeState.controller = vc
        return vc
    }
    
    func updateNSViewController(_ nsViewController: VMOSInternalVirtualMachineViewController, context: Context) {
        runtimeState.controller = nsViewController
    }

    static func dismantleNSViewController(_ nsViewController: VMOSInternalVirtualMachineViewController, coordinator: Coordinator) {
        nsViewController.prepareForWindowClose()
    }
}


#endif
