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
                .frame(minWidth: 800, minHeight: 600)
        }
        
        Window("Create Virtual Machine Guide", id: "create-machine-guide") {
            VMCreateStepperGuideView()
        }
        .defaultPosition(.center)
        .defaultSize(width: 1024, height: 768)
        
        WindowGroup(id: "start-machine", for: URL.self) { $modelRootPath in
            if let rootPath = modelRootPath {
                VMOSMainVirtualMachineView(rootPath: rootPath, recoveryMode: false)
            } else {
                Text("Invalid , just close")
            }
        }
        .defaultPosition(.center)
        .defaultSize(width: 1024, height: 768)
        
        
        WindowGroup(id: "start-machine-recovery", for: URL.self) { $modelRootPath in
            if let rootPath = modelRootPath {
                VMOSMainVirtualMachineView(rootPath: rootPath, recoveryMode: true)
            } else {
                Text("Invalid , just close")
            }
        }
        .defaultPosition(.center)
        .defaultSize(width: 1024, height: 768)
    }
}
