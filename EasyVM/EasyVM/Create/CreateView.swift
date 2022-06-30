//
//  CreateView.swift
//  EasyVM
//
//  Created by gipyzarc on 2022/6/29.
//

import SwiftUI

struct CreateView: View {
    var body: some View {
        VStack {
            Text("Create a new virtual machine:")
            Text("Create a new virtual machine:")
            Text("Create a new virtual machine:")
            Text("Create a new virtual machine:")
            Text("Create a new virtual machine:")
            Text("Create a new virtual machine:")
            
            
            Spacer()
            
            HStack {
                Spacer()
                Button {
                    
                } label: {
                    Label("Create", systemImage: "plus")
                }
            }
        }
        .padding(.all)
    }
}

struct CreateView_Previews: PreviewProvider {
    static var previews: some View {
        CreateView()
    }
}
