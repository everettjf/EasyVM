//
//  BodyView.swift
//  EasyVM
//
//  Created by everettjf on 2022/6/29.
//

import SwiftUI

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
    
    @StateObject private var vmStore = MachinesHomeStateObject()
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
                            print("open machine")
                            openWindow(id: "start-machine", value: item.rootPath)
                        })
                        .contextMenu {
                        let isRunning = VMRunningRegistry.shared.isRunning(rootPath: item.rootPath)

                        Button {
                            print("run")
                            openWindow(id: "start-machine", value: item.rootPath)
                        } label: {
                            Image(systemName: isRunning ? "macwindow" : "play")
                            Text(isRunning ? "Open Window" : "Run")
                        }

                        // starting a second instance on the same disk is unsafe
                        if item.model?.config.type == .macOS && !isRunning {
                            Button {
                                print("run")
                                openWindow(id: "start-machine-recovery", value: item.rootPath)
                            } label: {
                                Image(systemName: "play")
                                Text("Run into Recovery Mode")
                            }
                        }

                        Divider()

                        Button {
                            print("take snapshot now")
                            takeQuickSnapshot(item: item)
                        } label: {
                            Image(systemName: "camera")
                            Text("Take Snapshot Now")
                        }

                        Button {
                            print("snapshots")
                            snapshotItem = item
                        } label: {
                            Image(systemName: "camera.on.rectangle")
                            Text("Snapshots...")
                        }

                        Divider()

                        Button {
                            print("edit")
                            editingItem = item
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                            Text("Edit")
                        }

                        Button {
                            print("reveal")
                            MacKitUtil.revealInFinder(item.rootPath.path(percentEncoded: false))
                        } label: {
                            Image(systemName: "folder")
                            Text("Reveal in Finder")
                        }

                        Divider()

                        Button {
                            print("remove from list")
                            removeFromList(item: item)
                        } label: {
                            Image(systemName: "minus.circle")
                            Text("Remove from List")
                        }

                        Button {
                            print("move to trash")
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

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("EasyVM")
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
