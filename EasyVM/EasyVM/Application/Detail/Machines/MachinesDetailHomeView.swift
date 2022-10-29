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
    @Environment(\.openWindow) var openWindow
    
    @StateObject private var vmStore = MachinesHomeStateObject()
    @State private var editingItem: HomeItemVMModel?
    
    let columns = [GridItem(.adaptive(minimum: 230, maximum: 230))]
    
    var content: some View {
        VStack {
            if vmStore.vmItems.isEmpty {
                MachinesEmptyView()
            } else {
                grid
            }
        }
        .sheet(item: $editingItem) { item in
            VMEditConfigurationView(model: item.model!)
        }
    }
    
    var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .listRowSeparatorLeading) {
                ForEach(vmStore.vmItems) { item in
                    MachinesDetailCardWarpView(item: item, action: MachineDetailCardAction(onPlay: {
                        openWindow(id: "start-machine", value: item.rootPath)
                    }, onEdit: {
                        editingItem = item
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
                        
                        if item.model != nil && item.model!.config.type == .macOS {
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
                            Label("Create a new virutal machine", systemImage: "plus.diamond")
                        }
                    }
                    ToolbarItem(id: "add", placement: .primaryAction) {
                        Button(action: {
                            sharedAppConfigManager.addVMPathWithSelect()
                        }) {
                            Label("Add an existing virutal machine", systemImage: "folder.badge.plus")
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
