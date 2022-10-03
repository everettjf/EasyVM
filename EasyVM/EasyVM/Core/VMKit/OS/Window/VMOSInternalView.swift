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
    
    func makeNSViewController(context: Context) -> MacOSVMViewController {
        let vc = MacOSVMViewController()
        return vc
    }
    
    func updateNSViewController(_ nsViewController: MacOSVMViewController, context: Context) {
        
    }
}

