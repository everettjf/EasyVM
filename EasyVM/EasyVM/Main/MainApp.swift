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
            ContentView()
                .frame(minWidth: 700, minHeight: 500)
        }
        
        Window("Create Virtual Machine Guide", id: "create-machine-guide") {
            CreateStepperGuideView()
        }
        .defaultPosition(.center)
        .defaultSize(width: 700, height: 500)
        

        WindowGroup(id: "start-machine", for: URL.self) { $modelRootPath in
            VMOSMainViewForMacOS(rootPath: modelRootPath!)
        }
        
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
