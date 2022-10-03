//
//  VMOSInternalView.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI

struct VMOSInternalView : NSViewControllerRepresentable {
    let rootPath: URL
    
    class Coordinator : NSObject {
        var parent: VMOSInternalView
        
        init(_ parent: VMOSInternalView) {
            self.parent = parent
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSViewController(context: Context) -> VMOSInternalViewController {
        print("make ns view controller")
        let vc = VMOSInternalViewController()
        vc.rootPath = rootPath
        return vc
    }
    
    func updateNSViewController(_ nsViewController: VMOSInternalViewController, context: Context) {
        print("update ns view controller")
        
    }
}

