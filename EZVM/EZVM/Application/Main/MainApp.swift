//
//  EZVMApp.swift
//  EZVM
//
//  Created by everettjf on 2022/6/24.
//

import SwiftUI

@main
struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    
#if arch(arm64)
    var body: some Scene {
        WindowGroup {
            if HeadlessLaunchConfiguration.current == nil {
                ContentView()
                    .frame(minWidth: 800, minHeight: 600)
            } else {
                EmptyView()
            }
        }
        
        Window("Create Virtual Machine Guide", id: "create-machine-guide") {
            VMCreateStepperGuideView()
        }
        .defaultPosition(.center)
        .defaultSize(width: 960, height: 660)
        .windowResizability(.contentMinSize)
        
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

        Settings {
            VirtualizationFeaturesSettingsView()
        }
    }
#else
    
    var body: some Scene {
        WindowGroup {
            Text("App support only Apple Chips")
                .frame(minWidth: 800, minHeight: 600)
        }
    }
    
#endif
}

#if arch(arm64)
private struct VirtualizationFeaturesSettingsView: View {
    @AppStorage(EZVMExperimentalFeatures.guestProvisioningKey) private var guestProvisioning = false
    @AppStorage(EZVMExperimentalFeatures.diskImageKitSnapshotsKey) private var diskImageKitSnapshots = false
    @AppStorage(EZVMExperimentalFeatures.efiSecureBootKey) private var efiSecureBoot = false

    var body: some View {
        Form {
            Section("Virtualization capabilities") {
                ForEach(VirtualizationCapability.allCases) { capability in
                    HStack {
                        Label(capability.title, systemImage: capability.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                        Spacer()
                        Text("macOS \(capability.minimumMajorVersion)+")
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(capability.isAvailable ? .primary : .secondary)
                }
            }

            Section {
                featureToggle("macOS guest provisioning", isOn: $guestProvisioning, capability: .guestProvisioning)
                featureToggle("DiskImageKit snapshots", isOn: $diskImageKitSnapshots, capability: .diskImageKitSnapshots)
                featureToggle("EFI Secure Boot", isOn: $efiSecureBoot, capability: .efiSecureBoot)
            } header: {
                Text("Experimental macOS 27 features")
            } footer: {
                Text("These features use beta system APIs. Keep backups of important virtual machines.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .padding()
    }

    @ViewBuilder
    private func featureToggle(_ title: String, isOn: Binding<Bool>, capability: VirtualizationCapability) -> some View {
        Toggle(title, isOn: isOn)
            .disabled(!capability.isAvailable)
    }
}
#endif
