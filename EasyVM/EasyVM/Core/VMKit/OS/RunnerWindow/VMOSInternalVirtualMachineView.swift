//
//  VMOSInternalView.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI
import Observation

#if arch(arm64)
@MainActor
@Observable
final class VMRuntimeState {
    typealias Phase = VMRuntimePhase

    struct USBAccessoryItem: Identifiable, Equatable {
        let id: UInt64
        let name: String
        let detail: String
        var isAttached: Bool
    }

    private(set) var phase: Phase = .preparing
    private(set) var usbAccessories: [USBAccessoryItem] = []
    private(set) var usbStatusMessage: String?
    private(set) var balloonMemoryTarget: UInt64?
    private(set) var balloonMemoryMaximum: UInt64?
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
    var canManageUSB: Bool {
        if #available(macOS 27.0, *) {
            return UserDefaults.standard.bool(forKey: EasyVMExperimentalFeatures.usbPassthroughKey)
                && (phase == .running || phase == .paused)
        }
        return false
    }
    var canManageBalloon: Bool {
        balloonMemoryMaximum != nil && (phase == .running || phase == .paused)
    }

    func update(_ phase: Phase) {
        self.phase = phase
    }

    func updateUSBAccessories(_ accessories: [USBAccessoryItem], statusMessage: String? = nil) {
        usbAccessories = accessories
        usbStatusMessage = statusMessage
    }

    func updateBalloonMemory(target: UInt64?, maximum: UInt64?) {
        balloonMemoryTarget = target
        balloonMemoryMaximum = maximum
    }

    func pause() { controller?.pauseMachine() }
    func resume() { controller?.resumeMachine() }
    func requestStop() { controller?.requestStopMachine() }
    func saveAndStop() { controller?.saveAndStopMachine() }
    func forceStop() { controller?.forceStopMachine() }
    func toggleUSB(_ id: UInt64) { controller?.toggleUSBAccessory(registryID: id) }
    func setBalloonMemory(fraction: Double) { controller?.setBalloonMemory(fraction: fraction) }
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
