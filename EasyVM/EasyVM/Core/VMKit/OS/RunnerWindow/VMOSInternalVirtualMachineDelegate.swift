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
    
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let info = "!! Virtual machine did stop with error: \(error.localizedDescription)"
        print(info)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        let info = "!! Guest did stop virtual machine."
        print(info)
    }
}

#endif
