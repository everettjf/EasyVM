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
        
        Window("Create Virtual Machine", id: "createvm") {
            CreateView()
        }
        .defaultPosition(.center)
//        .keyboardShortcut("0")
//        .defaultPosition(.topLeading)
//        .defaultSize(width: 220, height: 250)
//
//
//        Window("Party Budget", id: "budget2") {
//            Text("Budget View2")
//        }
//        .keyboardShortcut("0")
//        .defaultPosition(.topLeading)
//        .defaultSize(width: 220, height: 250)
//
        MenuBarExtra("Bulletin Board", systemImage: "quote.bubble") {
            BulletinBoard()
        }
        .menuBarExtraStyle(.window)
    }
}
