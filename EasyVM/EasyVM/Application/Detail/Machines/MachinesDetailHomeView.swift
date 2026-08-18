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
    
    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 230))]
    
    private var content: some View {
        VStack {
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
    }
    
    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .listRowSeparatorLeading) {
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
                        Button {
                            print("run")
                            openWindow(id: "start-machine", value: item.rootPath)
                        } label: {
                            Image(systemName: "play")
                            Text("Run")
                        }
                        
                        if item.model?.config.type == .macOS {
                            Button {
                                print("run")
                                openWindow(id: "start-machine-recovery", value: item.rootPath)
                            } label: {
                                Image(systemName: "play")
                                Text("Run into Recovery Mode")
                            }
                        }
                        
                        Button {
                            print("reveal")
                            MacKitUtil.revealInFinder(item.rootPath.path(percentEncoded: false))
                        } label: {
                            Image(systemName: "folder")
                            Text("Reveal in Finder")
                        }
                        
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

                        Button {
                            print("edit")
                            editingItem = item
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                            Text("Edit")
                        }
                        
                        Button {
                            print("remove")
                            sharedAppConfigManager.removeVMPathWithReload(url: item.rootPath)
                        } label: {
                            Image(systemName: "delete.left")
                            Text("Remove")
                        }
                    }
                }
            }
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

    var body: some View {
        NavigationStack {
            content
                .padding(.leading, 5)
                .padding(.trailing, 5)
                .navigationTitle("Virtual Machines - EasyVM")
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
