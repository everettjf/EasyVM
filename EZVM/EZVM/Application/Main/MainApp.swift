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
        .windowToolbarStyle(.unifiedCompact)
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
        .windowToolbarStyle(.unifiedCompact)
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
        if HeadlessLaunchConfiguration.current == nil {
            CommandGroup(before: .windowList) {
                Button("Show Control Center") {
                    openWindow(id: "control-center")
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()
            }
        }
    }
}
#endif

#if arch(arm64)
private struct VirtualizationFeaturesSettingsView: View {
    @State private var capabilityRefreshID = UUID()
    @AppStorage(EZVMExperimentalFeatures.customVirGLGraphicsKey) private var customVirGLGraphics = true
    @AppStorage(VMThumbnailPreferences.screenCaptureEnabledKey) private var screenCaptureThumbnails = false
    @AppStorage(VMThumbnailPreferences.generatedStyleKey) private var generatedThumbnailStyle = VMGeneratedThumbnailStyle.aurora.rawValue

    var body: some View {
        Form {
            Section {
                ForEach(VirtualizationCapability.allCases) { capability in
                    HStack {
                        Label(capability.title, systemImage: capability.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                        Spacer()
                        Text("macOS \(capability.minimumMajorVersion)+")
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(capability.isAvailable ? .primary : .secondary)
                }
            } header: {
                Text("Virtualization capabilities")
            } footer: {
                Text("macOS guest iCloud identity is automatic for VMs created from a supported macOS restore image; upgrading an older VM does not add that identity. Metal improvements are supplied automatically by the supported host, guest, and Mac hardware model. Neither requires an additional EZVM entitlement.")
            }

            Section {
                ForEach(VMHostCapability.allCases) { capability in
                    HostCapabilityStatusRow(capability: capability, refreshID: capabilityRefreshID)
                }

                Button("Refresh Signed Capabilities", systemImage: "arrow.clockwise") {
                    capabilityRefreshID = UUID()
                }
            } header: {
                Text("Signed capabilities")
            } footer: {
                Text("These values come from the macOS 27 entitlements in the running EZVM process.")
            }

            Section {
                Label("DiskImageKit snapshots for ASIF disks", systemImage: "checkmark.circle.fill")
                Label("Per-VM EFI Secure Boot", systemImage: "checkmark.shield.fill")
                featureToggle(
                    "High-performance VirGL graphics for Linux",
                    isOn: $customVirGLGraphics,
                    capability: .customVirtio
                )
            } header: {
                Text("macOS 27 features")
            } footer: {
                Text("ASIF machines automatically use DiskImageKit layered snapshots. Linux virtual machines use the Custom Virtio GPU by default and can fall back to Apple graphics by turning this off. macOS virtual machines always use Apple's graphics stack.")
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
                    style: VMGeneratedThumbnailStyle(rawValue: generatedThumbnailStyle) ?? .aurora
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

private struct HostCapabilityStatusRow: View {
    let capability: VMHostCapability
    let refreshID: UUID

    var body: some View {
        let _ = refreshID
        let grantedKey = capability.grantedEntitlementKey()

        HStack(alignment: .firstTextBaseline) {
            Label(capability.title, systemImage: grantedKey == nil ? "xmark.circle" : "checkmark.circle.fill")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(grantedKey == nil ? "Missing" : "Granted")
                Text(grantedKey ?? capability.entitlementKeys.joined(separator: " or "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(grantedKey == nil ? .secondary : .primary)
        .accessibilityElement(children: .combine)
    }
}
#endif
