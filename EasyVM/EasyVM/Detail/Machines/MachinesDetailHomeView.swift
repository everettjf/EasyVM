//
//  BodyView.swift
//  EasyVM
//
//  Created by everettjf on 2022/6/29.
//

import SwiftUI

struct HomeItemVMModel : Identifiable {
    let id = UUID()
    let model: VMModel?
}

class MachinesHomeStateObject: ObservableObject {
    @Published var vmItems: [HomeItemVMModel] = []
    
    init() {
        sharedAppConfigManager.loadConfig()
        let rootPaths = sharedAppConfigManager.appConfig.rootPaths
        for rootPath in rootPaths {
            let rootURL = URL(filePath: rootPath)
            
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: rootURL.path(percentEncoded: false), isDirectory: &isDirectory) {
                // not existed
                vmItems.append(HomeItemVMModel(model: nil))
                continue
            }
            if !isDirectory.boolValue {
                // not directory
                vmItems.append(HomeItemVMModel(model: nil))
                continue
            }
            
            let loadModelResult = VMModel.loadConfigFromFile(path: rootURL)
            switch loadModelResult {
            case .failure(let error):
                print("load vm error : \(error)")
                vmItems.append(HomeItemVMModel(model: nil))
                continue
            case .success(let model):
                vmItems.append(HomeItemVMModel(model: model))
            }
        }
    }
}



struct MachinesDetailHomeView: View {
    @Environment(\.openWindow) var openWindow
    
    @StateObject private var vmStore = MachinesHomeStateObject()
    
    let columns = [GridItem(.adaptive(minimum: 230, maximum: 230))]
    
    var grid: some View {
        LazyVGrid(columns: columns, alignment: .listRowSeparatorLeading) {
            ForEach(vmStore.vmItems) { item in
                if let model = item.model {
                    MachineDetailCardView(model: model)
                } else {
                    Text("Invalid")
                }
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack {
                ScrollView {
                    grid
                }
            }
            .padding(.leading, 5)
            .padding(.trailing, 5)
            .navigationTitle("Virtual Machines - EasyVM")
            .toolbar(id: "toolbar") {
                ToolbarItem(id: "new", placement: .primaryAction) {
                    Button(action: {
                        openWindow(id: "create-machine-guide")
                    }) {
                        Label("New Virutal Machine", systemImage: "plus.diamond")
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
