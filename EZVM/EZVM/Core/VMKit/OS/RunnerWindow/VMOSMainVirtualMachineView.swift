//
//  VMOSMainViewForMacOS.swift
//  EZVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

#if arch(arm64)
struct VMOSMainVirtualMachineView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    let rootPath: URL
    let recoveryMode: Bool
    @State private var runtimeState = VMRuntimeState()
    @State private var isShowingCloseConfirmation = false
    @State private var settingsModel: VMModel?
    @State private var isShowingSharedFolderResult = false
    @State private var sharedFolderResult = ""
    @AppStorage(VMThumbnailPreferences.screenCaptureEnabledKey) private var screenCaptureThumbnails = false
    
    var body: some View {
        ZStack {
            // Keep letterboxing and the area exposed while the macOS toolbar
            // animates in or out visually continuous with the guest display.
            Color.black.ignoresSafeArea()

            VMOSInternalVirtualMachineView(
                rootPath: rootPath,
                recoveryMode: recoveryMode,
                runtimeState: runtimeState
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()

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
                                _ = try EZVMDiagnostics.export()
                            } catch let error as CocoaError where error.code == .userCancelled {
                                // The save panel was intentionally dismissed.
                            } catch {
                                EZVMLog.error("Diagnostic export failed: \(error.localizedDescription)")
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
                    Text(runtimeState.phase == .saving
                         ? "This window will close automatically when it is safe."
                         : "If the guest does not respond, EZVM will force stop it after 20 seconds.")
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

                if let backend = runtimeState.graphicsBackendKind {
                    Menu("Graphics", systemImage: "display") {
                        Text(backend == .customVirGL ? "Custom VirGL active" : "Apple Virtio active")
                        if let detail = runtimeState.graphicsBackendDetail {
                            Divider()
                            Text(detail)
                        }
                    }
                    .help(runtimeState.graphicsBackendDetail
                          ?? (backend == .customVirGL
                              ? "Custom VirGL acceleration is active"
                              : "Apple Virtio graphics is active"))
                }

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
                            if let inputDevices = status.inputDevices, !inputDevices.isEmpty {
                                Text("Input: \(inputDevices.joined(separator: ", "))")
                            }
                            if status.supportsSSH, !status.addresses.isEmpty {
                                Text("Addresses: \(status.addresses.joined(separator: ", "))")
                                Menu("Open SSH", systemImage: "terminal") {
                                    ForEach(status.addresses, id: \.self) { address in
                                        Button(address) {
                                            openSSH(address: address)
                                        }
                                    }
                                }
                            }
                            if status.supportsFileTransfer {
                                Divider()
                                Button("Upload File to Guest...", systemImage: "arrow.up.doc") {
                                    uploadFileToGuest()
                                }
                                .disabled(runtimeState.guestAgentTransferState.isActive)
                                Button("Download File from Guest...", systemImage: "arrow.down.doc") {
                                    downloadFileFromGuest()
                                }
                                .disabled(runtimeState.guestAgentTransferState.isActive)

                                transferStatusContent
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
                    if runtimeState.supportsMachineSaveRestore {
                        Button("Save State and Stop", systemImage: "square.and.arrow.down") {
                            runtimeState.saveAndStop()
                        }
                        .disabled(!runtimeState.canSave)
                    }

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
                    Button("Show Control Center", systemImage: "rectangle.grid.1x2") {
                        openWindow(id: "control-center")
                    }
                    .keyboardShortcut("0", modifiers: .command)

                    Divider()

                    Button("Choose Thumbnail Image…", systemImage: "photo") {
                        chooseThumbnailImage()
                    }

                    if screenCaptureThumbnails {
                        Button("Use Current Display as Thumbnail", systemImage: "photo.badge.checkmark") {
                            runtimeState.useCurrentDisplayAsThumbnail()
                        }
                        .disabled(runtimeState.phase != .running && runtimeState.phase != .paused)
                        .help("Replace the machine card thumbnail with the current virtual machine display")
                    }

                    Divider()

                    Button("Show in Finder", systemImage: "folder") {
                        MacKitUtil.revealInFinder(rootPath.path(percentEncoded: false))
                    }
                    Button("Export Diagnostics…", systemImage: "square.and.arrow.up") {
                        do {
                            _ = try EZVMDiagnostics.export()
                        } catch let error as CocoaError where error.code == .userCancelled {
                            // The save panel was intentionally dismissed.
                        } catch {
                            EZVMLog.error("Diagnostic export failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
        .navigationTitle(rootPath.deletingPathExtension().lastPathComponent)
        .background {
            VMWindowCloseObserver(rootPath: rootPath) {
                runtimeState.needsCloseConfirmation
            } shouldBlock: {
                runtimeState.isCloseInProgress
            } onCloseAttempt: {
                isShowingCloseConfirmation = true
            }
        }
        .alert(
            runtimeState.supportsMachineSaveRestore ? "Save State and Close?" : "Shut Down and Close?",
            isPresented: $isShowingCloseConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button(runtimeState.supportsMachineSaveRestore ? "Save State and Close" : "Shut Down and Close") {
                runtimeState.saveAndStopForWindowClose()
            }
        } message: {
            if runtimeState.supportsMachineSaveRestore {
                Text("EZVM will save the virtual machine’s current state, stop it, and then close this window. You can resume from the same state next time.")
            } else {
                Text("Custom VirGL state cannot be saved. EZVM will ask the guest to shut down, force stop only if it does not respond, and then close this window.")
            }
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

    @ViewBuilder
    private var transferStatusContent: some View {
        switch runtimeState.guestAgentTransferState {
        case .idle:
            EmptyView()
        case .preparing(let name):
            Divider()
            Text("Preparing \(name)...")
            Button("Cancel Transfer", role: .destructive) { runtimeState.cancelGuestAgentTransfer() }
        case .transferring(let direction, let name, let completed, let total):
            Divider()
            Text("\(direction == .upload ? "Uploading" : "Downloading") \(name): \(transferProgress(completed, total))")
            Button("Cancel Transfer", role: .destructive) { runtimeState.cancelGuestAgentTransfer() }
        case .completed(let message):
            Divider()
            Text(message)
        case .failed(let message):
            Divider()
            Text(message)
        case .cancelled:
            Divider()
            Text("Transfer cancelled")
        }
    }

    private func transferProgress(_ completed: UInt64, _ total: UInt64) -> String {
        let completedText = ByteCountFormatter.string(fromByteCount: Int64(completed), countStyle: .file)
        let totalText = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        return "\(completedText) of \(totalText)"
    }

    private func openSSH(address: String) {
        let alert = NSAlert()
        alert.messageText = "Open SSH Connection"
        alert.informativeText = "Enter the Linux username for \(address). EZVM does not store the username or any SSH credential."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "")
        field.placeholderString = "username"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let url = VMGuestAgentSSH.url(username: field.stringValue, address: address) else {
            MacKitUtil.alertWarn(title: "Invalid SSH destination", message: "Use a Linux username beginning with a letter and a valid IP address reported by the guest agent.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func uploadFileToGuest() {
        let panel = NSOpenPanel()
        panel.title = "Select a File to Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let localURL = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = "Upload “\(localURL.lastPathComponent)” to the Guest"
        alert.informativeText = "Enter an absolute Linux destination. The transfer is authenticated, checksum-verified, and committed atomically."
        alert.addButton(withTitle: "Upload")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        let field = NSTextField(string: "/tmp/\(localURL.lastPathComponent)")
        field.placeholderString = "/absolute/guest/path"
        let overwrite = NSButton(checkboxWithTitle: "Replace an existing regular file", target: nil, action: nil)
        stack.addArrangedSubview(field)
        stack.addArrangedSubview(overwrite)
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 56)
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try VMGuestAgentTransferValidator.validate(path: field.stringValue)
            runtimeState.guestAgentUpload(
                localURL: localURL, destinationPath: field.stringValue,
                overwrite: overwrite.state == .on
            )
        } catch {
            MacKitUtil.alertWarn(title: "Invalid guest destination", message: error.localizedDescription)
        }
    }

    private func downloadFileFromGuest() {
        let alert = NSAlert()
        alert.messageText = "Download File from Guest"
        alert.informativeText = "Enter the absolute path of a regular Linux file. Symbolic links are rejected."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "/tmp/")
        field.placeholderString = "/absolute/guest/path"
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try VMGuestAgentTransferValidator.validate(path: field.stringValue)
        } catch {
            MacKitUtil.alertWarn(title: "Invalid guest source", message: error.localizedDescription)
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save File from Guest"
        panel.nameFieldStringValue = URL(fileURLWithPath: field.stringValue).lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        runtimeState.guestAgentDownload(sourcePath: field.stringValue, destinationURL: destination)
    }

    private func openSettings() {
        guard case let .success(model) = VMModel.loadConfigFromFile(rootPath: rootPath) else {
            sharedFolderResult = "EZVM could not load this virtual machine’s settings."
            isShowingSharedFolderResult = true
            return
        }
        settingsModel = model
    }

    private func addSharedFolder() {
        MacKitUtil.selectDirectory(title: "Choose a Folder to Share") { url in
            guard let url else { return }
            guard case let .success(model) = VMModel.loadConfigFromFile(rootPath: rootPath) else {
                sharedFolderResult = "EZVM could not load this virtual machine’s settings."
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
                sharedFolderResult = "EZVM could not add the shared folder: \(error)"
            }
            isShowingSharedFolderResult = true
        }
    }

    private func chooseThumbnailImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Thumbnail Image"
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let source = panel.url,
              let image = NSImage(contentsOf: source) else { return }

        let maximumWidth: CGFloat = 720
        let scale = min(1, maximumWidth / max(image.size.width, 1))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        thumbnail.unlockFocus()
        guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            MacKitUtil.alertWarn(title: "Invalid thumbnail", message: "EZVM could not decode this image.")
            return
        }
        do {
            try png.write(to: rootPath.appending(path: "screenshot.png"), options: .atomic)
            NotificationCenter.default.post(name: AppConfigManager.newVMChangedNotification, object: nil)
        } catch {
            MacKitUtil.alertWarn(title: "Thumbnail not saved", message: error.localizedDescription)
        }
    }
}

struct VMOSMainViewForMacOS_Previews: PreviewProvider {
    static var previews: some View {
        VMOSMainVirtualMachineView(rootPath: URL(filePath: "/Users/everettjf/Downloads/MyVirtualMachine"), recoveryMode: false)
    }
}

#endif
