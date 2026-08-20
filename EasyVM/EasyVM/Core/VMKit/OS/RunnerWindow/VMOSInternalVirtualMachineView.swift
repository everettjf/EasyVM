//
//  VMOSInternalView.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI

#if arch(arm64)
@MainActor
final class VMRuntimeState: ObservableObject {
    struct USBAccessoryItem: Identifiable, Equatable {
        let id: UInt64
        let name: String
        let detail: String
        var isAttached: Bool
    }

    enum Phase: Equatable {
        case preparing
        case starting
        case restoring
        case running
        case pausing
        case paused
        case saving
        case stopping
        case stopped
        case failed(String)

        var title: String {
            switch self {
            case .preparing: "Preparing"
            case .starting: "Starting"
            case .restoring: "Restoring"
            case .running: "Running"
            case .pausing: "Pausing"
            case .paused: "Paused"
            case .saving: "Saving"
            case .stopping: "Stopping"
            case .stopped: "Stopped"
            case .failed: "Error"
            }
        }
    }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var usbAccessories: [USBAccessoryItem] = []
    @Published private(set) var usbStatusMessage: String?
    weak var controller: VMOSInternalVirtualMachineViewController?

    var errorMessage: String? {
        guard case let .failed(message) = phase else { return nil }
        return message
    }

    var canPause: Bool { phase == .running }
    var canResume: Bool { phase == .paused }
    var canRequestStop: Bool { phase == .running || phase == .paused }
    var canSave: Bool { phase == .running || phase == .paused }
    var canManageUSB: Bool {
        if #available(macOS 27.0, *) {
            return UserDefaults.standard.bool(forKey: EasyVMExperimentalFeatures.usbPassthroughKey)
                && (phase == .running || phase == .paused)
        }
        return false
    }

    func update(_ phase: Phase) {
        self.phase = phase
    }

    func updateUSBAccessories(_ accessories: [USBAccessoryItem], statusMessage: String? = nil) {
        usbAccessories = accessories
        usbStatusMessage = statusMessage
    }

    func pause() { controller?.pauseMachine() }
    func resume() { controller?.resumeMachine() }
    func requestStop() { controller?.requestStopMachine() }
    func saveAndStop() { controller?.saveAndStopMachine() }
    func toggleUSB(_ id: UInt64) { controller?.toggleUSBAccessory(registryID: id) }
}

struct VMOSInternalVirtualMachineView : NSViewControllerRepresentable {
    let rootPath: URL
    let recoveryMode: Bool
    @ObservedObject var runtimeState: VMRuntimeState
    
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
        print("make ns view controller")
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
