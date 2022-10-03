//
//  EasyVMContainerView.swift
//  EasyVM
//
//  Created by everettjf on 2022/6/26.
//

import SwiftUI

struct MacOSVMContainerView: View {
    
    @State var isStartVM = false
    
    var body: some View {
        VStack {
            HStack {
                Image(systemName: "globe")
                    .imageScale(.large)
                    .foregroundColor(.accentColor)
                Button {
                    // start
                    isStartVM.toggle()
                } label: {
                    Label("Start", systemImage: "play")
                }
                
                Spacer()
            }
            
            EasyVMView(isStartVM: $isStartVM)
        }
    }
}

struct EasyVMContainerView_Previews: PreviewProvider {
    static var previews: some View {
        MacOSVMContainerView()
    }
}
