//
//  CreateView.swift
//  EasyVM
//
//  Created by gipyzarc on 2022/6/29.
//

import SwiftUI
import AppKit

struct VMCreateView: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("Create a new virtual machine:")
            
            
            Button {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                if panel.runModal() != .OK {
                    return
                }
                    
                guard let ipswPath = panel.url else {
                    return
                }
                
                sharedMacOSInstaller.installWithIPSW(ipswPath: ipswPath)
            } label: {
                Label("Create macOS with ipsw", systemImage: "plus")
            }
            Button {
                sharedMacOSInstaller.installWithOnline()
            } label: {
                Label("Create macOS with online download", systemImage: "plus")
            }
            
            Button {
                
            } label: {
                Label("Create Linux with ISO", systemImage: "plus")
            }
            
            
            Spacer()
        }
        .padding(.all)
    }
}

struct CreateView_Previews: PreviewProvider {
    static var previews: some View {
        VMCreateView()
    }
}
