//
//  ContentView.swift
//  EasyVM
//
//  Created by gipyzarc on 2022/6/24.
//

import SwiftUI

struct ContentView: View {
    
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
