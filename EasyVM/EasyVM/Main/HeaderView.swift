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
                openWindow(id: "create-vm")
            } label: {
                Label("Create VM", systemImage: "plus")
            }
            Button {
                openWindow(id: "demo-vm-macos")
            } label: {
                Label("Open macOS VM", systemImage: "tray")
            }
            Button {
                openWindow(id: "demo-vm-linux")
            } label: {
                Label("Open Linux VM", systemImage: "scribble")
            }
            
            Spacer()
        }
        .padding(.all, 5)
    }
}

struct HeaderView_Previews: PreviewProvider {
    static var previews: some View {
        HeaderView()
    }
}
