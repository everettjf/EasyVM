//
//  VMOSInternalViewController.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import Cocoa
import Foundation
import Virtualization


class MacOSVMViewControllerDelegate: NSObject, VZVirtualMachineDelegate {
    
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let info = "!! Virtual machine did stop with error: \(error.localizedDescription)"
        print(info)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        let info = "!! Guest did stop virtual machine."
        print(info)
    }
}

public class VMOSInternalViewController: NSViewController {
    // parameters
    let rootPath: URL? = nil
    
    // internal
    private var virtualMachineView: VZVirtualMachineView!
    private var virtualMachineResponder: MacOSVMViewControllerDelegate?
    private var virtualMachine: VZVirtualMachine!
    

    public override func loadView() {
        view = NSView()
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        // Do view setup here.
        
        virtualMachineView = VZVirtualMachineView()
        view.addSubview(virtualMachineView)
        
        NSLayoutConstraint.activate([
            virtualMachineView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            virtualMachineView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            virtualMachineView.topAnchor.constraint(equalTo: view.topAnchor),
            virtualMachineView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        DispatchQueue.main.async {
            self.startMachine()
        }
    }
    
    private func startMachine() {
        
        // load model from path
        
    }

    
}
