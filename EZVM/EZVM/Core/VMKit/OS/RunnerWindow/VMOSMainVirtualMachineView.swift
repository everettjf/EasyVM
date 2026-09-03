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
    @State private var isSharedFolderDropTargeted = false
    @State private var provisioningConfirmationUsername: String?
    @State private var isShowingManualSetupConfirmation = false
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
            // macOS may reuse the state of a dismissed WindowGroup(value:)
            // when the same VM URL is opened again. A fresh identity guarantees
            // that a stopped VZVirtualMachine is never presented a second time.
            .id(runtimeState.launchIdentity)
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

            if runtimeState.guestAgentTransferState.isActive {
                guestTransferOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(18)
            }

            macGuestProvisioningOverlay
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 16)
                .padding(.horizontal, 18)

            if runtimeState.graphicsBackendKind == .customVirGL,
               let graphicsIssue = runtimeState.graphicsBackendDetail {
                VMGraphicsRuntimeBanner(detail: graphicsIssue, openSettings: openSettings)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 16)
                    .padding(.leading, 18)
            }

            VMNetworkRuntimeBanner(
                state: runtimeState.networkRuntimeState,
                reconnect: runtimeState.reconnectNetworkDevice
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 16)
            .padding(.trailing, 18)

            if let notice = runtimeState.machineStateNotice {
                VMMachineStateNoticeView(
                    message: notice,
                    dismiss: runtimeState.dismissMachineStateNotice
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
        .overlay {
            if isSharedFolderDropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.accentColor.opacity(0.16))
                    .overlay {
                        Label("Drop folders to share now", systemImage: "folder.fill.badge.plus")
                            .font(.title3.weight(.semibold))
                            .padding(18)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(24)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            addDroppedSharedFolders(urls)
        } isTargeted: {
            isSharedFolderDropTargeted = $0
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
                .help("Choose a host folder to share with the running virtual machine")
                .accessibilityHint("Choose a folder to share with this virtual machine")

                if let backend = runtimeState.graphicsBackendKind {
                    let graphicsNeedsAttention = backend == .customVirGL
                        && runtimeState.graphicsBackendDetail != nil
                    Menu {
                        Text(graphicsNeedsAttention
                             ? "Custom VirGL needs attention"
                             : (backend == .customVirGL ? "Custom VirGL active" : "Apple Virtio active"))
                        if let detail = runtimeState.graphicsBackendDetail {
                            Divider()
                            Text(detail)
                        }
                    } label: {
                        Label(
                            "Graphics",
                            systemImage: graphicsNeedsAttention
                                ? "exclamationmark.triangle.fill"
                                : "display"
                        )
                    }
                    .help(runtimeState.graphicsBackendDetail
                          ?? (backend == .customVirGL
                              ? "Custom VirGL acceleration is active"
                              : "Apple Virtio graphics is active"))
                    .accessibilityLabel(graphicsNeedsAttention ? "Graphics needs attention" : "Graphics")
                }

                if runtimeState.networkRuntimeState != .unavailable {
                    VMNetworkRuntimeMenu(
                        state: runtimeState.networkRuntimeState,
                        reconnect: runtimeState.reconnectNetworkDevice
                    )
                }

                Menu(
                    runtimeState.usbPassthroughState.menuTitle,
                    systemImage: runtimeState.usbPassthroughState.menuSystemImage
                ) {
                    usbPassthroughContent
                }
                .disabled(!runtimeState.canManageUSBPassthrough)
                .help(runtimeState.usbPassthroughState.menuHelp)
                .accessibilityLabel("USB accessories")
                .accessibilityValue(runtimeState.usbPassthroughState.accessibilityValue)
                .accessibilityHint("Open USB accessory controls")

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
                    Button("Save State and Stop", systemImage: "square.and.arrow.down") {
                        runtimeState.saveAndStop()
                    }
                    .disabled(!runtimeState.canSave)
                    .help(runtimeState.machineStateUnavailabilityReason ?? "Pause, save, and stop this virtual machine")

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
            runtimeState.canPersistMachineState ? "Save State and Close?" : "Shut Down and Close?",
            isPresented: $isShowingCloseConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button(runtimeState.canPersistMachineState ? "Save State and Close" : "Shut Down and Close") {
                runtimeState.saveAndStopForWindowClose()
            }
        } message: {
            if runtimeState.canPersistMachineState {
                Text("EZVM will save the virtual machine’s current state, stop it, and then close this window. You can resume from the same state next time.")
            } else if runtimeState.hasAttachedUSBAccessories {
                Text("A USB accessory is connected. EZVM will shut down the guest instead of saving machine state so the accessory is released safely.")
            } else {
                Text("\(runtimeState.machineStateUnavailabilityReason ?? "Machine state is unavailable for this configuration.") EZVM will ask the guest to shut down, force stop only if it does not respond, and then close this window.")
            }
        }
        .alert("Shared Folder", isPresented: $isShowingSharedFolderResult) {
            Button("OK") {}
        } message: {
            Text(sharedFolderResult)
        }
        .alert(
            "Remove Temporary Password?",
            isPresented: Binding(
                get: { provisioningConfirmationUsername != nil },
                set: { if !$0 { provisioningConfirmationUsername = nil } }
            )
        ) {
            Button("Keep Password", role: .cancel) {
                provisioningConfirmationUsername = nil
            }
            Button("Remove Password", role: .destructive) {
                provisioningConfirmationUsername = nil
                runtimeState.confirmMacGuestProvisioningCompleted()
            }
        } message: {
            Text("Confirm that you can sign in as “\(provisioningConfirmationUsername ?? "the new account")”. EZVM will permanently remove the temporary provisioning password from this Mac’s Keychain. This cannot be undone.")
        }
        .alert("Use macOS Setup Assistant Instead?", isPresented: $isShowingManualSetupConfirmation) {
            Button("Keep Automatic Setup", role: .cancel) {}
            Button("Use Setup Assistant", role: .destructive) {
                runtimeState.useManualMacSetup()
            }
        } message: {
            Text("EZVM will permanently remove the pending password from this Mac’s Keychain and will not submit automatic account setup again. Continue in Setup Assistant if the VM is running; otherwise close this window and run the VM again.")
        }
        .sheet(item: $settingsModel) { model in
            VMEditConfigurationView(model: model, appliesSharedFoldersImmediately: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ezvmConfigurationSaved)) { notification in
            guard let savedRoot = notification.object as? URL,
                  savedRoot.standardizedFileURL == rootPath.standardizedFileURL,
                  let configuration = notification.userInfo?["configuration"] as? VMConfigModel,
                  let error = runtimeState.updateSharedFolders(configuration.directorySharingDevices) else {
                return
            }
            sharedFolderResult = "Settings were saved, but the running shared folders could not be updated: \(error) They will match after the next start."
            isShowingSharedFolderResult = true
        }
        .onChange(of: runtimeState.phase) { _, phase in
            guard phase.shouldDismissMachineWindow else { return }
            dismissWindow(
                id: recoveryMode ? "start-machine-recovery" : "start-machine",
                value: rootPath
            )
        }
        .onAppear {
            // `dismissWindow` hides the scene, but AppKit/SwiftUI can retain its
            // @State for the next `openWindow` with the same value. Recreate the
            // runtime and representable so the next Run owns a new controller,
            // lease, graphics backend, and VZVirtualMachine instance.
            if runtimeState.phase.shouldDismissMachineWindow {
                runtimeState = VMRuntimeState()
            }
        }
    }

    private func memoryDescription(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    @ViewBuilder
    private var macGuestProvisioningOverlay: some View {
        switch runtimeState.macGuestProvisioningState {
        case .unavailable:
            EmptyView()
        case .applying(let username):
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preparing the macOS account")
                        .font(.headline)
                    Text("macOS is applying the first-boot settings for “\(username)”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        case .needsVerification(let username):
            provisioningVerificationCard(
                username: username,
                title: "Check the macOS account",
                detail: "The previous provisioning attempt was interrupted. Sign in as “\(username)” if the account exists; otherwise choose Retry Next Start. EZVM will not submit it again automatically."
            )
        case .awaitingConfirmation(let username):
            provisioningVerificationCard(
                username: username,
                title: "Confirm macOS setup",
                detail: "After you can sign in as “\(username)”, confirm to remove the temporary password from this Mac’s Keychain."
            )
        case .retryPrepared(let username):
            Label(
                "Provisioning for “\(username)” is ready to retry once. If this VM is running, shut it down; then close this window and run the VM again.",
                systemImage: "arrow.clockwise.circle.fill"
            )
            .font(.callout)
            .foregroundStyle(.blue)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        case .manualSetup:
            Label(
                "Automatic account setup is off. Continue in macOS Setup Assistant, or close and run this VM again if it is not currently running.",
                systemImage: "person.crop.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        case .completed:
            Label("macOS setup confirmed — temporary password removed", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
        case .failed(let message):
            HStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                Button("Use Setup Assistant") {
                    isShowingManualSetupConfirmation = true
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        }
    }

    private func provisioningVerificationCard(
        username: String,
        title: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Use Setup Assistant") {
                    isShowingManualSetupConfirmation = true
                }
                .buttonStyle(.bordered)
                .help("Remove the pending credential and stop automatic account setup")
                Button("Retry Next Start") {
                    runtimeState.retryMacGuestProvisioningOnNextStart()
                }
                .buttonStyle(.bordered)
                .help("Keep the temporary credential and submit provisioning again on the next VM start")
                Button("Setup Complete") {
                    provisioningConfirmationUsername = username
                }
                .buttonStyle(.borderedProminent)
                .help("Remove the temporary provisioning credential after verifying the account in the guest")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("macOS guest provisioning for \(username)")
        .frame(maxWidth: 720)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
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
    private var usbPassthroughContent: some View {
        switch runtimeState.usbPassthroughState {
        case .idle:
            Text("No USB accessories requested")
            Button("Choose USB Accessories…", systemImage: "plus") {
                runtimeState.discoverUSBAccessories()
            }
        case .discovering:
            Text("Waiting for Accessory Access…")
        case .unavailable(let message):
            Label(message, systemImage: "exclamationmark.lock")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
            Button("Try Again", systemImage: "arrow.clockwise") {
                runtimeState.discoverUSBAccessories()
            }
        case .ready(let snapshot):
            if let notice = snapshot.notice {
                Label(notice.message, systemImage: "exclamationmark.triangle")
                Button("Dismiss", systemImage: "xmark") {
                    runtimeState.dismissUSBPassthroughNotice()
                }
                Divider()
            }
            if snapshot.devices.isEmpty {
                Text("No approved USB accessories are connected")
            } else {
                ForEach(snapshot.devices) { device in
                    switch snapshot.operations[device.registryID] {
                    case .attaching:
                        Button("Connecting \(device.menuTitle)…", systemImage: "hourglass") {}
                            .disabled(true)
                    case .detaching:
                        Button("Disconnecting \(device.menuTitle)…", systemImage: "hourglass") {}
                            .disabled(true)
                    case nil where snapshot.attachedRegistryIDs.contains(device.registryID):
                        Button("Disconnect \(device.menuTitle)", systemImage: "eject") {
                            runtimeState.detachUSBAccessory(registryID: device.registryID)
                        }
                    case nil:
                        Button("Connect \(device.menuTitle)", systemImage: "cable.connector.horizontal") {
                            runtimeState.attachUSBAccessory(registryID: device.registryID)
                        }
                    }
                }
            }
            Divider()
            if snapshot.canChooseMoreAccessories {
                Button("Choose More USB Accessories…", systemImage: "plus") {
                    runtimeState.discoverUSBAccessories()
                }
            } else {
                Text("Disconnect USB accessories before choosing others")
            }
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

    @ViewBuilder
    private var guestTransferOverlay: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(guestTransferOverlayTitle).font(.headline)
            }
            if case let .transferring(_, _, completed, total) = runtimeState.guestAgentTransferState,
               total > 0 {
                ProgressView(value: Double(completed), total: Double(total))
                    .frame(width: 280)
                Text(transferProgress(completed, total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Cancel Transfer", role: .destructive) {
                runtimeState.cancelGuestAgentTransfer()
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
        .shadow(radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest-agent-transfer-progress")
    }

    private var guestTransferOverlayTitle: String {
        switch runtimeState.guestAgentTransferState {
        case .preparing(let name): "Preparing \(name)"
        case .transferring(let direction, let name, _, _):
            "\(direction == .upload ? "Uploading" : "Downloading") \(name)"
        default: "File Transfer"
        }
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
                if let error = runtimeState.updateSharedFolders(state.getConfigModel().directorySharingDevices) {
                    sharedFolderResult = "“\(url.lastPathComponent)” was saved, but could not be shared now: \(error) It will be available after the next start."
                } else {
                    sharedFolderResult = "“\(url.lastPathComponent)” is now shared with this virtual machine."
                }
            case .failure(let error):
                sharedFolderResult = "EZVM could not add the shared folder: \(error)"
            }
            isShowingSharedFolderResult = true
        }
    }

    private func addDroppedSharedFolders(_ urls: [URL]) -> Bool {
        let directories = VMSharedFolderDrop.directories(from: urls)
        guard !directories.isEmpty else {
            sharedFolderResult = "Only folders can be shared with a virtual machine."
            isShowingSharedFolderResult = true
            return false
        }
        guard case let .success(model) = VMModel.loadConfigFromFile(rootPath: rootPath) else {
            sharedFolderResult = "EZVM could not load this virtual machine’s settings."
            isShowingSharedFolderResult = true
            return false
        }
        let state = VMConfigurationViewStateObject(configModel: model.config)
        let added = directories.reduce(into: 0) { count, url in
            if state.addSharedDirectory(url) { count += 1 }
        }
        guard added > 0 else {
            sharedFolderResult = "Those folders are already shared."
            isShowingSharedFolderResult = true
            return false
        }
        switch state.getConfigModel().writeConfigToFile(path: model.configURL) {
        case .success:
            NotificationCenter.default.post(name: AppConfigManager.newVMChangedNotification, object: nil)
            if let error = runtimeState.updateSharedFolders(state.getConfigModel().directorySharingDevices) {
                sharedFolderResult = "Saved \(added) shared folder\(added == 1 ? "" : "s"), but could not share them now: \(error) They will be available after the next start."
            } else {
                sharedFolderResult = "Now sharing \(added) new folder\(added == 1 ? "" : "s") with this virtual machine."
            }
            isShowingSharedFolderResult = true
            return true
        case .failure(let error):
            sharedFolderResult = "EZVM could not add the shared folders: \(error)"
            isShowingSharedFolderResult = true
            return false
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

private struct VMGraphicsRuntimeBanner: View {
    let detail: String
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Graphics needs attention")
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Settings", action: openSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityHint("Open settings to select Apple Virtio graphics for the next start")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: .rect(cornerRadius: 11))
        .shadow(color: .black.opacity(0.16), radius: 9, y: 3)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
    }
}

private struct VMNetworkRuntimeMenu: View {
    let state: VMNetworkRuntimeState
    let reconnect: (Int) -> Void

    var body: some View {
        Menu {
            Text(summary)
            if !state.issues.isEmpty {
                Divider()
                ForEach(state.issues) { issue in
                    Text("\(issue.title): \(issue.reason)")
                    Button("Reconnect \(issue.title)", systemImage: "arrow.clockwise") {
                        reconnect(issue.deviceIndex)
                    }
                    .disabled(state.reconnectingDeviceIndices.contains(issue.deviceIndex))
                }
            }
        } label: {
            Label("Network", systemImage: symbol)
        }
        .help(summary)
        .accessibilityLabel("Virtual machine network")
        .accessibilityValue(summary)
    }

    private var symbol: String {
        switch state {
        case .unavailable: "network.slash"
        case .preparing: "network"
        case .connected: "network"
        case .hostSleeping: "moon.zzz"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .degraded: "network.slash"
        }
    }

    private var summary: String {
        switch state {
        case .unavailable: "No virtual network adapter"
        case .preparing(let count): "Preparing \(adapterCount(count))"
        case .connected(let count): "\(adapterCount(count)) connected"
        case .hostSleeping(let count): "\(adapterCount(count)) suspended while this Mac sleeps"
        case .reconnecting(_, _, let deviceIndices): "Recovering \(issueCount(deviceIndices.count))"
        case .degraded(_, let issues): "\(issueCount(issues.count)) disconnected"
        }
    }

    private func adapterCount(_ count: Int) -> String {
        "\(count) network adapter\(count == 1 ? "" : "s")"
    }

    private func issueCount(_ count: Int) -> String {
        "\(count) network adapter\(count == 1 ? "" : "s")"
    }
}

private struct VMNetworkRuntimeBanner: View {
    let state: VMNetworkRuntimeState
    let reconnect: (Int) -> Void

    var body: some View {
        switch state {
        case .reconnecting(_, let issues, let deviceIndices):
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Recovering \(reconnectingTitle(issues: issues, deviceIndices: deviceIndices))…")
                    .font(.callout.weight(.medium))
            }
            .networkRuntimeCard()
        case .degraded(_, let issues):
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Image(systemName: "network.slash")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(issues.count == 1
                             ? "Network adapter needs attention"
                             : "\(issues.count) network adapters need attention")
                            .font(.callout.weight(.semibold))
                    }
                    ForEach(issues) { issue in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.title)
                                    .font(.caption.weight(.semibold))
                                Text(issue.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Reconnect") {
                                reconnect(issue.deviceIndex)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityLabel("Reconnect \(issue.title)")
                        }
                        if issue.id != issues.last?.id {
                            Divider()
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .networkRuntimeCard()
            }
        case .unavailable, .preparing, .connected, .hostSleeping:
            EmptyView()
        }
    }

    private func reconnectingTitle(issues: [VMNetworkDeviceIssue], deviceIndices: [Int]) -> String {
        guard deviceIndices.count == 1,
              let index = deviceIndices.first,
              let issue = issues.first(where: { $0.deviceIndex == index }) else {
            return "network adapters"
        }
        return issue.title
    }
}

private extension View {
    func networkRuntimeCard() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: .rect(cornerRadius: 11))
            .shadow(color: .black.opacity(0.16), radius: 9, y: 3)
            .frame(maxWidth: 520)
    }
}

private struct VMMachineStateNoticeView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Saved Session Status")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .accessibilityHint("Dismiss the saved-session status message")
        }
        .padding(14)
        .frame(maxWidth: 620, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved session status")
    }
}

struct VMOSMainViewForMacOS_Previews: PreviewProvider {
    static var previews: some View {
        VMOSMainVirtualMachineView(rootPath: URL(filePath: "/Users/everettjf/Downloads/MyVirtualMachine"), recoveryMode: false)
    }
}

#endif
