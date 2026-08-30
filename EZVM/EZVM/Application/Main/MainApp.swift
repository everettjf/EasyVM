//
//  EZVMApp.swift
//  EZVM
//
//  Created by everettjf on 2022/6/24.
//

import SwiftUI
import CoreGraphics

@main
struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    
#if arch(arm64)
    var body: some Scene {
        WindowGroup("Control Center", id: "control-center") {
            if HeadlessLaunchConfiguration.current == nil {
                ContentView()
                    .frame(minWidth: 800, minHeight: 600)
            } else {
                EmptyView()
            }
        }
        .defaultPosition(.center)
        .defaultSize(width: 1080, height: 760)
        .windowResizability(.contentMinSize)
        
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
        .commands {
            ControlCenterCommands()
        }
        
        
        WindowGroup(id: "start-machine-recovery", for: URL.self) { $modelRootPath in
            if let rootPath = modelRootPath {
                VMOSMainVirtualMachineView(rootPath: rootPath, recoveryMode: true)
            } else {
                Text("Invalid , just close")
            }
        }
        .defaultPosition(.center)
        .defaultSize(width: 1024, height: 768)
        .commands {
            ControlCenterCommands()
        }

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
private struct ControlCenterCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("Show Control Center") {
                openWindow(id: "control-center")
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()
        }
    }
}
#endif

#if arch(arm64)
private struct VirtualizationFeaturesSettingsView: View {
    @AppStorage(EZVMExperimentalFeatures.guestProvisioningKey) private var guestProvisioning = false
    @AppStorage(EZVMExperimentalFeatures.diskImageKitSnapshotsKey) private var diskImageKitSnapshots = false
    @AppStorage(EZVMExperimentalFeatures.efiSecureBootKey) private var efiSecureBoot = false
    @AppStorage(EZVMExperimentalFeatures.customVirGLGraphicsKey) private var customVirGLGraphics = false
    @AppStorage(VMThumbnailPreferences.screenCaptureEnabledKey) private var screenCaptureThumbnails = false
    @AppStorage(VMThumbnailPreferences.generatedStyleKey) private var generatedThumbnailStyle = VMGeneratedThumbnailStyle.arcade.rawValue

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
                featureToggle(
                    "Custom VirGL graphics backend",
                    isOn: $customVirGLGraphics,
                    capability: .customVirtio
                )
            } header: {
                Text("Experimental macOS 27 features")
            } footer: {
                Text("The VirGL switch currently enables backend selection and safe fallback only; the existing Apple display backend remains active until the runtime module is linked. These features use beta system APIs.")
            }

            Section {
                Toggle("Capture the virtual machine display", isOn: $screenCaptureThumbnails)
                    .onChange(of: screenCaptureThumbnails) { _, enabled in
                        if enabled && !CGPreflightScreenCaptureAccess() {
                            screenCaptureThumbnails = CGRequestScreenCaptureAccess()
                        }
                    }

                Picker("Generated cover style", selection: $generatedThumbnailStyle) {
                    ForEach(VMGeneratedThumbnailStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }

                GeneratedMachineThumbnailView(
                    title: "Omarchy",
                    type: .linux,
                    style: VMGeneratedThumbnailStyle(rawValue: generatedThumbnailStyle) ?? .arcade
                )
                .frame(height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } header: {
                Text("Thumbnails")
            } footer: {
                Text(screenCaptureThumbnails
                    ? "Enabled by you. macOS requires Screen & System Audio Recording permission. Turn this off to stop EZVM from capturing VM windows."
                    : "Off by default. EZVM uses a generated title cover and never requests screen recording permission.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
        .padding()
    }

    @ViewBuilder
    private func featureToggle(_ title: String, isOn: Binding<Bool>, capability: VirtualizationCapability) -> some View {
        Toggle(title, isOn: isOn)
            .disabled(!capability.isAvailable)
    }
}
#endif
