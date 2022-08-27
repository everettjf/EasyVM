//
//  EasyVMView.swift
//  EasyVM
//
//  Created by everettjf on 2022/6/24.
//

import SwiftUI


struct MacOSVMInternalView : NSViewControllerRepresentable {
    @Binding var isStartVM: Bool
    
    class Coordinator : NSObject {
        var parent: MacOSVMInternalView
        
        init(_ parent: MacOSVMInternalView) {
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
        
        if isStartVM {
            print("start vm ")
            
            nsViewController.startVM()
        }
    }
}



struct EasyVMView: View {
    @Binding var isStartVM: Bool
    
    
    var body: some View {
        MacOSVMInternalView(isStartVM: $isStartVM)
    }
}

struct EasyVMView_Previews: PreviewProvider {
    static var previews: some View {
        EasyVMView(isStartVM: .constant(false))
    }
}
