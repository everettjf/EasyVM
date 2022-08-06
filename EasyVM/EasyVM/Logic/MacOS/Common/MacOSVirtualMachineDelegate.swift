/*
See LICENSE folder for this sample’s licensing information.

Abstract:
A class that conforms to `VZVirtualMachineDelegate` and to track the virtual machine's state.
*/

import Foundation
import Virtualization

class MacOSVirtualMachineDelegate: NSObject, VZVirtualMachineDelegate {
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        NSLog("Virtual machine did stop with error: \(error.localizedDescription)")
        exit(-1)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        NSLog("Guest did stop virtual machine.")
        exit(0)
    }
}
