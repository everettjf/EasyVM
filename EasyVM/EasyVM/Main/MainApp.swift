//
//  EasyVMApp.swift
//  EasyVM
//
//  Created by everettjf on 2022/6/24.
//

import SwiftUI

@main
struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
//            ContentView()
            StepperGuideView()
                .frame(minWidth: 600, minHeight: 400)
        }
        
        Window("Create Virtual Machine Guide", id: "create-machine-guide") {
            CreateMachineGuideView()
        }
        .defaultPosition(.center)
        .defaultSize(width: 800, height: 700)
        

//        Window("macOS Virtual Machine", id: "demo-vm-macos") {
//            MacOSVMContainerView()
//        }
//        .defaultPosition(.center)
//        .defaultSize(width: 600, height: 400)
//
//
//        Window("Linux Virtual Machine", id: "demo-vm-linux") {
//            LinuxVMContainerView()
//        }
//        .defaultPosition(.center)
//        .defaultSize(width: 600, height: 400)
        

    }
}
