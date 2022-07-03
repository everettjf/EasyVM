//
//  EasyVMView.swift
//  EasyVM
//
//  Created by gipyzarc on 2022/6/24.
//

import SwiftUI


struct EasyVMInternalView : NSViewControllerRepresentable {
    @Binding var isStartVM: Bool
    
    class Coordinator : NSObject {
        var parent: EasyVMInternalView
        
        init(_ parent: EasyVMInternalView) {
            self.parent = parent
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSViewController(context: Context) -> EasyVMViewController {
        let vc = EasyVMViewController()
        return vc
    }
    
    func updateNSViewController(_ nsViewController: EasyVMViewController, context: Context) {
        
        if isStartVM {
            print("start vm ")
            
            nsViewController.startVM()
        }
    }
}



struct EasyVMView: View {
    @Binding var isStartVM: Bool
    
    
    var body: some View {
        EasyVMInternalView(isStartVM: $isStartVM)
    }
}

struct EasyVMView_Previews: PreviewProvider {
    static var previews: some View {
        EasyVMView(isStartVM: .constant(false))
    }
}
