//
//  VMOSMainViewForMacOS.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI
import AppKit

#if arch(arm64)
struct VMOSMainVirtualMachineView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    let rootPath: URL
    let recoveryMode: Bool
    @State private var runtimeState = VMRuntimeState()
    @State private var isShowingCloseConfirmation = false
    @State private var settingsModel: VMModel?
    @State private var isShowingSharedFolderResult = false
    @State private var sharedFolderResult = ""
    
    var body: some View {
        ZStack {
            VMOSInternalVirtualMachineView(
                rootPath: rootPath,
                recoveryMode: recoveryMode,
                runtimeState: runtimeState
            )

            if let errorMessage = runtimeState.errorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    Text("Virtual Machine Error")
                        .font(.title2.weight(.semibold))
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    HStack {
                        Button("Copy Error", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(errorMessage, forType: .string)
                        }
                        Button("Export Diagnostics", systemImage: "square.and.arrow.up") {
                            do {
                                _ = try EasyVMDiagnostics.export()
                            } catch let error as CocoaError where error.code == .userCancelled {
                                // The save panel was intentionally dismissed.
                            } catch {
                                EasyVMLog.error("Diagnostic export failed: \(error.localizedDescription)")
                            }
                        }
                    }
                }
                .padding(40)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 16))
            }

            if runtimeState.isCloseInProgress {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(runtimeState.phase == .saving ? "Saving Virtual Machine State…" : "Stopping Virtual Machine…")
                        .font(.headline)
                    Text("This window will close automatically when it is safe.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
                .background(.regularMaterial, in: .rect(cornerRadius: 16))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Settings", systemImage: "gearshape") {
                    openSettings()
                }
                .help("Edit virtual machine settings; changes apply after the next start")
                .accessibilityHint("Open settings for this virtual machine")

                Button("Add Shared Folder", systemImage: "folder.badge.plus") {
                    addSharedFolder()
                }
                .help("Choose a host folder to share after the next start")
                .accessibilityHint("Choose a folder to share with this virtual machine")

                if let target = runtimeState.balloonMemoryTarget,
                   let maximum = runtimeState.balloonMemoryMaximum {
                    Menu("Memory", systemImage: "memorychip") {
                        Text("Guest target: \(memoryDescription(target)) of \(memoryDescription(maximum))")
                        Divider()
                        ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                            Button("\(Int(fraction * 100))% — \(memoryDescription(UInt64(Double(maximum) * fraction)))") {
                                runtimeState.setBalloonMemory(fraction: fraction)
                            }
                            .disabled(!runtimeState.canManageBalloon)
                        }
                    }
                    .help("Request a Linux guest memory balloon target")
                }

                if runtimeState.guestAgentState != .unavailable {
                    Menu("Guest Agent", systemImage: guestAgentSymbol) {
                        Text(guestAgentSummary)
                        if case let .ready(status) = runtimeState.guestAgentState {
                            Text("Host: \(status.hostName)")
                            Text("OS: \(status.operatingSystem)")
                            if !status.addresses.isEmpty {
                                Text("Addresses: \(status.addresses.joined(separator: ", "))")
                            }
                            Divider()
                            Button("Shut Down Guest", systemImage: "power") {
                                runtimeState.guestAgentShutdown()
                            }
                            Button("Restart Guest", systemImage: "arrow.clockwise") {
                                runtimeState.guestAgentRestart()
                            }
                        }
                    }
                    .help(guestAgentSummary)
                }

                if runtimeState.canPause {
                    Button("Pause", systemImage: "pause") {
                        runtimeState.pause()
                    }
                    .accessibilityHint("Pause this virtual machine")
                }

                if runtimeState.canResume {
                    Button("Resume", systemImage: "play") {
                        runtimeState.resume()
                    }
                    .accessibilityHint("Resume this virtual machine")
                }

                Menu("Power", systemImage: "power") {
                    Button("Save State and Stop", systemImage: "square.and.arrow.down") {
                        runtimeState.saveAndStop()
                    }
                    .disabled(!runtimeState.canSave)

                    Button("Shut Down", systemImage: "power") {
                        runtimeState.requestStop()
                    }
                    .disabled(!runtimeState.canRequestStop)

                    Divider()

                    Button("Force Stop", systemImage: "stop.circle", role: .destructive) {
                        runtimeState.forceStop()
                    }
                    .disabled(!runtimeState.canForceStop)
                    .help("Immediately stop the virtual machine when the guest does not respond")
                }

                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Show in Finder", systemImage: "folder") {
                        MacKitUtil.revealInFinder(rootPath.path(percentEncoded: false))
                    }
                    Button("Export Diagnostics…", systemImage: "square.and.arrow.up") {
                        do {
                            _ = try EasyVMDiagnostics.export()
                        } catch let error as CocoaError where error.code == .userCancelled {
                            // The save panel was intentionally dismissed.
                        } catch {
                            EasyVMLog.error("Diagnostic export failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
        .navigationTitle(rootPath.deletingPathExtension().lastPathComponent)
        .background {
            VMWindowCloseObserver {
                runtimeState.needsCloseConfirmation
            } shouldBlock: {
                runtimeState.isCloseInProgress
            } onCloseAttempt: {
                isShowingCloseConfirmation = true
            }
        }
        .alert("Save State and Close?", isPresented: $isShowingCloseConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Save State and Close") {
                runtimeState.saveAndStopForWindowClose()
            }
        } message: {
            Text("EasyVM will save the virtual machine’s current state, stop it, and then close this window. You can resume from the same state next time.")
        }
        .alert("Shared Folder", isPresented: $isShowingSharedFolderResult) {
            Button("OK") {}
        } message: {
            Text(sharedFolderResult)
        }
        .sheet(item: $settingsModel) { model in
            VMEditConfigurationView(model: model)
        }
        .onChange(of: runtimeState.phase) { _, phase in
            guard phase.shouldDismissMachineWindow else { return }
            dismissWindow(
                id: recoveryMode ? "start-machine-recovery" : "start-machine",
                value: rootPath
            )
        }
    }

    private func memoryDescription(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private var guestAgentSymbol: String {
        switch runtimeState.guestAgentState {
        case .ready: "checkmark.circle"
        case .connecting, .authenticating: "arrow.triangle.2.circlepath"
        case .notEnrolled: "key.slash"
        case .disconnected: "exclamationmark.triangle"
        case .unavailable: "questionmark.circle"
        }
    }

    private var guestAgentSummary: String {
        switch runtimeState.guestAgentState {
        case .unavailable: "Guest Agent unavailable"
        case .notEnrolled: "Guest Agent is not enrolled"
        case .connecting: "Connecting to Guest Agent"
        case .authenticating: "Authenticating Guest Agent"
        case .ready(let status): "Guest Agent \(status.agentVersion) is ready"
        case .disconnected(let reason): "Guest Agent disconnected: \(reason)"
        }
    }

    private func openSettings() {
        guard case let .success(model) = VMModel.loadConfigFromFile(rootPath: rootPath) else {
            sharedFolderResult = "EasyVM could not load this virtual machine’s settings."
            isShowingSharedFolderResult = true
            return
        }
        settingsModel = model
    }

    private func addSharedFolder() {
        MacKitUtil.selectDirectory(title: "Choose a Folder to Share") { url in
            guard let url else { return }
            guard case let .success(model) = VMModel.loadConfigFromFile(rootPath: rootPath) else {
                sharedFolderResult = "EasyVM could not load this virtual machine’s settings."
                isShowingSharedFolderResult = true
                return
            }
            let state = VMConfigurationViewStateObject(configModel: model.config)
            guard state.addSharedDirectory(url) else {
                sharedFolderResult = "“\(url.lastPathComponent)” is already shared with this virtual machine."
                isShowingSharedFolderResult = true
                return
            }
            switch state.getConfigModel().writeConfigToFile(path: model.configURL) {
            case .success:
                NotificationCenter.default.post(name: AppConfigManager.newVMChangedNotification, object: nil)
                sharedFolderResult = "“\(url.lastPathComponent)” was added. It will be available after the next virtual machine start."
            case .failure(let error):
                sharedFolderResult = "EasyVM could not add the shared folder: \(error)"
            }
            isShowingSharedFolderResult = true
        }
    }
}

struct VMOSMainViewForMacOS_Previews: PreviewProvider {
    static var previews: some View {
        VMOSMainVirtualMachineView(rootPath: URL(filePath: "/Users/everettjf/Downloads/MyVirtualMachine"), recoveryMode: false)
    }
}

#endif
