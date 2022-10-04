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
            VMCreateStepperGuideView()
        }
        .defaultPosition(.center)
        .defaultSize(width: 700, height: 500)
        

        WindowGroup(id: "start-machine", for: URL.self) { $modelRootPath in
            if let rootPath = modelRootPath {
                VMOSMainVirtualMachineView(rootPath: rootPath)
            } else {
                Text("Invalid , just close")
            }
        }
        .defaultPosition(.center)
        .defaultSize(width: 700, height: 500)
        
    }
}
