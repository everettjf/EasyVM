//
//  VMOSInternalView.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI

struct VMOSInternalVirtualMachineView : NSViewControllerRepresentable {
    let rootPath: URL
    let recoveryMode: Bool
    
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
        return vc
    }
    
    func updateNSViewController(_ nsViewController: VMOSInternalVirtualMachineViewController, context: Context) {
        print("update ns view controller")
        
    }
}

