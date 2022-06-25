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
                .frame(minWidth: 800, minHeight: 600)
        }
    }
}
