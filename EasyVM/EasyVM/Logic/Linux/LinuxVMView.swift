//
//  LinuxVMView.swift
//  EasyVM
//
//  Created by everettjf on 2022/7/5.
//

import SwiftUI

struct LinuxVMView: NSViewControllerRepresentable {
    
    class Coordinator: NSObject {
        var parent: LinuxVMView
        
        init(_ parent: LinuxVMView) {
            self.parent = parent
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSViewController(context: Context) -> LinuxVMViewController {
        let vc = LinuxVMViewController()
        return vc
    }
    
    func updateNSViewController(_ nsViewController: LinuxVMViewController, context: Context) {
        
    }
}

struct LinuxVMView_Previews: PreviewProvider {
    static var previews: some View {
        LinuxVMView()
    }
}
