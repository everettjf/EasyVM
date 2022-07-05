//
//  EasyVMApp.swift
//  EasyVM
//
//  Created by gipyzarc on 2022/6/24.
//

import SwiftUI

@main
struct EasyVMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 600, minHeight: 400)
        }
        
        Window("Create Virtual Machine", id: "create-vm") {
            VMCreateView()
        }
        .defaultPosition(.center)
        .defaultSize(width: 400, height: 400)
        
        
        
        Window("macOS Virtual Machine", id: "demo-vm-macos") {
            MacOSVMContainerView()
        }
        .defaultPosition(.center)
        .defaultSize(width: 600, height: 400)
        
        
        Window("Linux Virtual Machine", id: "demo-vm-linux") {
            LinuxVMContainerView()
        }
        .defaultPosition(.center)
        .defaultSize(width: 600, height: 400)
        
        
        MenuBarExtra("Bulletin Board", systemImage: "quote.bubble") {
            BulletinBoard()
        }
        .menuBarExtraStyle(.window)
    }
}
