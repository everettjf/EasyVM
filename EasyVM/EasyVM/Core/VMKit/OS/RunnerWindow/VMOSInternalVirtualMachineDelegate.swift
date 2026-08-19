//
//  VMOSInternalVirtualMachineDelegate.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/5.
//

import Cocoa
import Foundation
import Virtualization

#if arch(arm64)
class VMOSInternalVirtualMachineDelegate: NSObject, VZVirtualMachineDelegate {

    let rootPath: URL?

    init(rootPath: URL?) {
        self.rootPath = rootPath
        super.init()
    }

    private func markStopped() {
        guard let rootPath = rootPath else {
            return
        }
        Task { @MainActor in
            VMRunningRegistry.shared.markStopped(rootPath: rootPath)
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let info = "!! Virtual machine did stop with error: \(error.localizedDescription)"
        print(info)
        markStopped()
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        let info = "!! Guest did stop virtual machine."
        print(info)
        markStopped()
    }
}

#endif
