//
//  BodyView.swift
//  EasyVM
//
//  Created by everettjf on 2022/6/29.
//

import SwiftUI

struct HomeItemVMModel : Identifiable {
    let id = UUID()
    let rootPath: URL
    let model: VMModel?
}

class MachinesHomeStateObject: ObservableObject {
    @Published var vmItems: [HomeItemVMModel] = []
    
    init() {
        reload()
        
        NotificationCenter.default.addObserver(forName: AppConfigManager.NewVMChangedNotification, object: nil, queue: OperationQueue.main) { [weak self] notification in
            DispatchQueue.main.async {
                self?.reload()
            }
        }
    }
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func reload() {
        sharedAppConfigManager.loadConfig()
        vmItems.removeAll()
        let rootPaths = sharedAppConfigManager.appConfig.rootPaths
        for rootPath in rootPaths {
            let rootURL = URL(filePath: rootPath)
            
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: rootURL.path(percentEncoded: false), isDirectory: &isDirectory) {
                // not existed
                vmItems.append(HomeItemVMModel(rootPath: rootURL, model: nil))
                continue
            }
            if !isDirectory.boolValue {
                // not directory
                vmItems.append(HomeItemVMModel(rootPath: rootURL, model: nil))
                continue
            }
            
            let loadModelResult = VMModel.loadConfigFromFile(rootPath: rootURL)
            switch loadModelResult {
            case .failure(let error):
                print("load vm error : \(error)")
                vmItems.append(HomeItemVMModel(rootPath: rootURL, model: nil))
                continue
            case .success(let model):
                vmItems.append(HomeItemVMModel(rootPath: rootURL, model: model))
            }
        }
    }
}

struct MachinesDetailCardWarpView: View {
    
    let item: HomeItemVMModel
    
    
    var invalid: some View {
        VStack {
            Text("Invalid")
                .font(.title)
                .padding(.all)
            Text(item.rootPath.path(percentEncoded: false))
                .font(.caption)
                .lineLimit(5)
                .multilineTextAlignment(.leading)
        }
        .padding(.all, 10)
        .frame(width: 230, height: 330)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(.gray, lineWidth: 1)
        )
        .padding(.all, 5)
    }
    
    var body: some View {
        if let model = item.model {
            MachineDetailCardView(model: model)
        } else {
            invalid
        }
    }
}


struct MachinesDetailHomeView: View {
    @Environment(\.openWindow) var openWindow
    
    @StateObject private var vmStore = MachinesHomeStateObject()
    
    let columns = [GridItem(.adaptive(minimum: 230, maximum: 230))]
    
    var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .listRowSeparatorLeading) {
                ForEach(vmStore.vmItems) { item in
                    MachinesDetailCardWarpView(item: item)
                        .onTapGesture(count: 2, perform: {
                            print("open machine")
                        })
                        .contextMenu {
                            Button {
                                print("open")
                            } label: {
                                Image(systemName: "play")
                                Text("Run")
                            }
                            Button {
                                print("open")
                            } label: {
                                Image(systemName: "folder")
                                Text("Reveal in Finder")
                            }
                            
                            Button {
                                print("edit")
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
    
    var empty: some View {
        MachinesEmptyView()
    }
    
    var content: some View {
        VStack {
            if vmStore.vmItems.isEmpty {
                empty
            } else {
                grid
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
                    ToolbarItem(id: "share", placement: .automatic) {
                        Button(action: {}) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
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
