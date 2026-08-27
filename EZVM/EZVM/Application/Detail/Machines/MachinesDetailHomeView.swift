//
//  BodyView.swift
//  EZVM
//
//  Created by everettjf on 2022/6/29.
//

import SwiftUI
import AppKit
import Virtualization

#if arch(arm64)
struct MachinesDetailCardWarpView: View {
    
    let item: HomeItemVMModel
    let action: MachineDetailCardAction
    
    var body: some View {
        if let model = item.model {
            MachineDetailCardView(item: item, model: model, action: action)
        } else {
            MachineDetailInvalidCardView(item: item)
        }
    }
}


struct MachinesDetailHomeView: View {
    @Environment(\.openWindow) private var openWindow
    
    @State private var vmStore = MachinesHomeStateObject()
    @State private var editingItem: HomeItemVMModel?
    @State private var snapshotItem: HomeItemVMModel?
    @State private var supportDestination: SupportDestination?
    
    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 18)]

    private enum SupportDestination: String, Identifiable {
        case communityFeedback
        case about

        var id: String { rawValue }
    }
    
    private var content: some View {
        VStack(spacing: 0) {
            if vmStore.vmItems.isEmpty {
                MachinesEmptyView()
            } else {
                grid
            }
        }
        .sheet(item: $editingItem) { item in
            if let model = item.model {
                VMEditConfigurationView(model: model)
            }
        }
        .sheet(item: $snapshotItem) { item in
            if let model = item.model {
                MachineSnapshotsView(machineName: model.config.name, rootPath: item.rootPath)
            }
        }
        .sheet(item: $supportDestination) { destination in
            VStack(spacing: 0) {
                NavigationStack {
                    Group {
                        switch destination {
                        case .communityFeedback:
                            CommunityDetailHomeView()
                        case .about:
                            AboutDetailHomeView()
                        }
                    }
                    .frame(minWidth: 580, minHeight: 500)
                }

                Divider()

                HStack {
                    Spacer()
                    Button("Close") {
                        supportDestination = nil
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("support.close")
                }
                .padding(12)
            }
        }
    }
    
    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your virtual machines")
                            .font(.title2.weight(.semibold))
                        Text("\(vmStore.vmItems.count) machine\(vmStore.vmItems.count == 1 ? "" : "s") ready on this Mac")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(vmStore.vmItems) { item in
                        MachinesDetailCardWarpView(item: item, action: MachineDetailCardAction(onPlay: {
                            openWindow(id: "start-machine", value: item.rootPath)
                        }, onEdit: {
                            editingItem = item
                        }, onSnapshots: {
                            snapshotItem = item
                        }))
                        .onTapGesture(count: 2, perform: {
                            openWindow(id: "start-machine", value: item.rootPath)
                        })
                        .contextMenu {
                        let isRunning = VMRunningRegistry.shared.isRunning(rootPath: item.rootPath)

                        Button {
                            openWindow(id: "start-machine", value: item.rootPath)
                        } label: {
                            Image(systemName: isRunning ? "macwindow" : "play")
                            Text(isRunning ? "Open Window" : "Run")
                        }

                        // starting a second instance on the same disk is unsafe
                        if item.model?.config.type == .macOS && !isRunning {
                            Button {
                                openWindow(id: "start-machine-recovery", value: item.rootPath)
                            } label: {
                                Image(systemName: "play")
                                Text("Run into Recovery Mode")
                            }
                        }

                        Divider()

                        Button {
                            takeQuickSnapshot(item: item)
                        } label: {
                            Image(systemName: "camera")
                            Text("Take Snapshot Now")
                        }

                        Button {
                            snapshotItem = item
                        } label: {
                            Image(systemName: "camera.on.rectangle")
                            Text("Snapshots...")
                        }

                        if let model = item.model, model.hasConvertibleRawDisk, !isRunning {
                            Button {
                                convertDiskToASIF(item: item, model: model)
                            } label: {
                                Image(systemName: "internaldrive")
                                Text("Convert Disk to ASIF...")
                            }
                        }

                        if let model = item.model, !isRunning {
                            Button {
                                cloneMachine(model)
                            } label: {
                                Image(systemName: "square.on.square")
                                Text("Clone...")
                            }

                            Button {
                                exportMachine(model)
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                Text("Export...")
                            }
                        }

                        if let model = item.model,
                           model.config.type == .linux,
                           (model.config.linuxFeatures ?? .legacy).virtioSocketEnabled {
                            Button {
                                exportGuestAgentEnrollment(model)
                            } label: {
                                Image(systemName: "key.horizontal")
                                Text("Export Guest Agent Enrollment...")
                            }
                        }

                        Divider()

                        Button {
                            editingItem = item
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                            Text("Edit")
                        }

                        Button {
                            MacKitUtil.revealInFinder(item.rootPath.path(percentEncoded: false))
                        } label: {
                            Image(systemName: "folder")
                            Text("Reveal in Finder")
                        }

                        Divider()

                        Button {
                            removeFromList(item: item)
                        } label: {
                            Image(systemName: "minus.circle")
                            Text("Remove from List")
                        }

                        Button {
                            moveToTrash(item: item)
                        } label: {
                            Image(systemName: "trash")
                            Text("Move to Trash")
                        }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
    
    func takeQuickSnapshot(item: HomeItemVMModel) {
        let rootPath = item.rootPath
        if VMRunningRegistry.shared.isRunning(rootPath: rootPath) {
            MacKitUtil.alertWarn(title: "Machine is running", message: "Shut down the virtual machine before taking a snapshot.")
            return
        }

        Task.detached {
            let result = VMSnapshotManager.createSnapshot(vmRootPath: rootPath, name: VMSnapshotManager.defaultSnapshotName())
            await MainActor.run {
                switch result {
                case .success(let snapshot):
                    NotificationCenter.default.post(name: AppConfigManager.newVMChangedNotification, object: nil)
                    MacKitUtil.alertInfo(title: "Snapshot created", message: snapshot.name)
                case .failure(let error):
                    MacKitUtil.alertWarn(title: "Snapshot failed", message: error)
                }
            }
        }
    }

    func removeFromList(item: HomeItemVMModel) {
        let name = item.model?.config.name ?? item.rootPath.lastPathComponent
        let path = item.rootPath.path(percentEncoded: false)
        MacKitUtil.alertWarn(title: "Remove \"\(name)\" from the list?", message: "The machine files stay on disk at \(path). You can add the machine back at any time.") { isOK in
            if isOK {
                sharedAppConfigManager.removeVMPathWithReload(url: item.rootPath)
            }
        }
    }

    func convertDiskToASIF(item: HomeItemVMModel, model: VMModel) {
        MacKitUtil.alertWarn(
            title: "Convert \"\(model.config.name)\" to ASIF?",
            message: "EZVM will create a space-efficient ASIF disk and keep the original raw disk as a backup. The machine must remain stopped during conversion."
        ) { isOK in
            guard isOK else { return }
            Task.detached {
                let result = model.convertPrimaryRawDiskToASIF()
                await MainActor.run {
                    switch result {
                    case .success:
                        NotificationCenter.default.post(name: AppConfigManager.newVMChangedNotification, object: nil)
                        MacKitUtil.alertInfo(title: "Disk converted", message: "The VM now uses ASIF. The original raw disk remains in the VM bundle with a .raw-backup extension.")
                    case .failure(let error):
                        MacKitUtil.alertWarn(title: "Conversion failed", message: error)
                    }
                }
            }
        }
    }

    func moveToTrash(item: HomeItemVMModel) {
        if VMRunningRegistry.shared.isRunning(rootPath: item.rootPath) {
            MacKitUtil.alertWarn(title: "Machine is running", message: "Shut down the virtual machine before moving it to the Trash.")
            return
        }

        let name = item.model?.config.name ?? item.rootPath.lastPathComponent
        MacKitUtil.alertWarn(title: "Move \"\(name)\" to the Trash?", message: "The whole machine bundle, including its snapshots, will be moved to the Trash. You can put it back from the Trash.") { isOK in
            guard isOK else {
                return
            }
            do {
                try FileManager.default.trashItem(at: item.rootPath, resultingItemURL: nil)
                sharedAppConfigManager.removeVMPathWithReload(url: item.rootPath)
            } catch {
                MacKitUtil.alertWarn(title: "Failed to move to Trash", message: error.localizedDescription)
            }
        }
    }

    func cloneMachine(_ model: VMModel) {
        guard let maintenanceLease = VMRunningRegistry.shared.acquire(rootPath: model.rootPath, phase: .maintaining) else {
            MacKitUtil.alertWarn(title: "Machine is busy", message: "Shut down the virtual machine and wait for other maintenance operations before cloning it.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Clone Virtual Machine"
        panel.nameFieldStringValue = "\(model.config.name) Copy.ezvm"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, var destination = panel.url else {
            VMRunningRegistry.shared.release(maintenanceLease)
            return
        }
        if destination.pathExtension != "ezvm" { destination.appendPathExtension("ezvm") }
        let cloneName = destination.deletingPathExtension().lastPathComponent
        let identifier = model.config.type == .macOS
            ? VZMacMachineIdentifier().dataRepresentation
            : VZGenericMachineIdentifier().dataRepresentation
        let source = model.rootPath
        Task.detached {
            let result = VMPortabilityManager.clone(
                sourceURL: source,
                destinationURL: destination,
                newName: cloneName,
                machineIdentifierData: identifier
            )
            await MainActor.run {
                VMRunningRegistry.shared.release(maintenanceLease)
                switch result {
                case .success:
                    sharedAppConfigManager.addVMPathWithRefresh(url: destination)
                    MacKitUtil.alertInfo(title: "Clone complete", message: "Created \(cloneName). The clone has a new machine identity and starts with a new snapshot history.")
                case .failure(let error):
                    MacKitUtil.alertWarn(title: "Clone failed", message: error)
                }
            }
        }
    }

    func exportMachine(_ model: VMModel) {
        guard let maintenanceLease = VMRunningRegistry.shared.acquire(rootPath: model.rootPath, phase: .maintaining) else {
            MacKitUtil.alertWarn(title: "Machine is busy", message: "Shut down the virtual machine and wait for other maintenance operations before exporting it.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Virtual Machine"
        panel.nameFieldStringValue = "\(model.config.name).ezvmexport"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, var destination = panel.url else {
            VMRunningRegistry.shared.release(maintenanceLease)
            return
        }
        if destination.pathExtension != VMPortabilityManager.exportExtension {
            destination.appendPathExtension(VMPortabilityManager.exportExtension)
        }
        let source = model.rootPath
        Task.detached {
            let result = VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: destination)
            await MainActor.run {
                VMRunningRegistry.shared.release(maintenanceLease)
                switch result {
                case .success: MacKitUtil.alertInfo(title: "Export complete", message: destination.path)
                case .failure(let error): MacKitUtil.alertWarn(title: "Export failed", message: error)
                }
            }
        }
    }

    func exportGuestAgentEnrollment(_ model: VMModel) {
        MacKitUtil.alertWarn(
            title: "Export Guest Agent Secret?",
            message: "This enrollment file allows software inside the Linux guest to authenticate as “\(model.config.name)”. Keep it private, install it only in that VM, and delete the exported copy afterward."
        ) { isOK in
            guard isOK else { return }
            guard let identifier = try? Data(contentsOf: model.machineIdentifierURL) else {
                MacKitUtil.alertWarn(title: "Enrollment failed", message: "The VM machine identifier is unreadable.")
                return
            }
            switch VMGuestAgentEnrollmentStore.loadOrCreate(machineIdentifierData: identifier) {
            case .failure(let error):
                MacKitUtil.alertWarn(title: "Enrollment failed", message: error)
            case .success(let enrollment):
                do {
                    let panel = NSSavePanel()
                    panel.title = "Export Guest Agent Enrollment"
                    panel.nameFieldStringValue = "EZVM-Agent-Enrollment-\(model.config.name).json"
                    panel.canCreateDirectories = true
                    guard panel.runModal() == .OK, var destination = panel.url else { return }
                    if destination.pathExtension.lowercased() != "json" { destination.appendPathExtension("json") }
                    let data = try VMGuestAgentEnrollmentStore.installationConfiguration(enrollment)
                    try data.write(to: destination, options: [.atomic])
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                    MacKitUtil.alertInfo(
                        title: "Enrollment exported",
                        message: "Install this file with the EZVM Guest Agent inside “\(model.config.name)”, then delete the exported copy. The host token remains protected in Keychain."
                    )
                } catch {
                    MacKitUtil.alertWarn(title: "Enrollment failed", message: error.localizedDescription)
                }
            }
        }
    }

    func importMachine() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select an EZVM Export"
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        guard openPanel.runModal() == .OK, let source = openPanel.url else { return }
        guard source.pathExtension == VMPortabilityManager.exportExtension else {
            MacKitUtil.alertWarn(title: "Import failed", message: "Select a .ezvmexport package.")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Import Virtual Machine"
        let suggested = source.deletingPathExtension().lastPathComponent
        savePanel.nameFieldStringValue = "\(suggested).ezvm"
        savePanel.canCreateDirectories = true
        guard savePanel.runModal() == .OK, var destination = savePanel.url else { return }
        if destination.pathExtension != "ezvm" { destination.appendPathExtension("ezvm") }
        let importedName = destination.deletingPathExtension().lastPathComponent
        let exportedConfig = source
            .appendingPathComponent(VMPortabilityManager.payloadDirectoryName, isDirectory: true)
            .appendingPathComponent("config.json")
        let exportedType = (try? JSONSerialization.jsonObject(with: Data(contentsOf: exportedConfig)))
            .flatMap { $0 as? [String: Any] }?["type"] as? String
        let identifier = exportedType == "macOS"
            ? VZMacMachineIdentifier().dataRepresentation
            : VZGenericMachineIdentifier().dataRepresentation
        Task.detached {
            let result = VMPortabilityManager.importMachine(
                exportURL: source,
                destinationURL: destination,
                identityMode: .copy(machineIdentifierData: identifier, name: importedName)
            )
            await MainActor.run {
                switch result {
                case .success:
                    sharedAppConfigManager.addVMPathWithRefresh(url: destination)
                    MacKitUtil.alertInfo(title: "Import complete", message: destination.lastPathComponent)
                case .failure(let error): MacKitUtil.alertWarn(title: "Import failed", message: error)
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("EZVM")
                .toolbar(id: "toolbar") {
                    ToolbarItem(id: "new", placement: .primaryAction) {
                        Button(action: {
                            openWindow(id: "create-machine-guide")
                        }) {
                            Label("Create a new virtual machine", systemImage: "plus.diamond")
                        }
                    }
                    ToolbarItem(id: "add", placement: .primaryAction) {
                        Button(action: {
                            sharedAppConfigManager.addVMPathWithSelect()
                        }) {
                            Label("Add an existing virtual machine", systemImage: "folder.badge.plus")
                        }
                    }
                    ToolbarItem(id: "import", placement: .primaryAction) {
                        Button(action: importMachine) {
                            Label("Import an EZVM export", systemImage: "square.and.arrow.down")
                        }
                    }
                    ToolbarItem(id: "more", placement: .primaryAction) {
                        Menu {
                            Button("Community & Feedback", systemImage: "person.2.wave.2") {
                                supportDestination = .communityFeedback
                            }
                            Divider()
                            Button("About", systemImage: "info.circle") {
                                supportDestination = .about
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("home.more-menu")
                    }
//                    ToolbarItem(id: "share", placement: .automatic) {
//                        Button(action: {
//
//                        }) {
//                            Label("Share", systemImage: "square.and.arrow.up")
//                        }
//                    }
                }
        }
    }
    
}

struct MachinesDetailHomeView_Previews: PreviewProvider {
    static var previews: some View {
        MachinesDetailHomeView()
            .frame(width: 500, height: 400)
    }
}

#endif
