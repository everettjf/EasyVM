//
//  VMConfigurationDirectorySharingDevicesView.swift
//  EZVM
//
//  Created by everettjf on 2022/10/5.
//

import SwiftUI

#if arch(arm64)
struct VMConfigurationDirectorySharingDevicesView: View {
    @Environment(VMConfigurationViewStateObject.self) var configData
    @State private var showingEditView = false
    
    
    var body: some View {
        content
            .sheet(isPresented: $showingEditView) {
                VMConfigurationDirectorySharingDevicesEditView()
            }
    }
    
    var content: some View {
        LabeledContent("Shared Folders") {
            VStack(alignment: .trailing) {
                List(configData.directorySharingDevices) { item in
                    HStack {
                        Spacer()
                        Text(item.data.items.map(\.name).joined(separator: ", "))
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .frame(width:400)
                
                HStack {
                    Spacer()
                    Button {
                        MacKitUtil.selectDirectory(title: "Choose a Folder to Share") { url in
                            guard let url else { return }
                            _ = configData.addSharedDirectory(url)
                        }
                    } label: {
                        Label("Add Shared Folder", systemImage: "folder.badge.plus")
                    }
                    .help("Choose a folder to share")

                    Button {
                        showingEditView.toggle()
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .help("Manage shared folders")
                }
            }
        }
    }
}

struct VMConfigurationDirectorySharingDevicesView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            VMConfigurationDirectorySharingDevicesView()
                .environment(VMConfigurationViewStateObject())
        }
        .formStyle(.grouped)
    }
}


#endif
