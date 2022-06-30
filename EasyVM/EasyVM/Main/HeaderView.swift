//
//  HeaderView.swift
//  EasyVM
//
//  Created by gipyzarc on 2022/6/29.
//

import SwiftUI

struct HeaderView: View {
    @Environment(\.openWindow) var openWindow
    var body: some View {
        HStack {
            Button {
                openWindow(id: "createvm")
            } label: {
                Label("New Virtual Machine", systemImage: "plus")
            }
            
            Spacer()
        }
        .padding(.all)
    }
}

struct HeaderView_Previews: PreviewProvider {
    static var previews: some View {
        HeaderView()
    }
}
