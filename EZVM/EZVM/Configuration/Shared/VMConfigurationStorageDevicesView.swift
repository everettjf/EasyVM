//
//  VMConfigurationStorageDevicesView.swift
//  EZVM
//
//  Created by everettjf on 2022/9/29.
//

import SwiftUI

#if arch(arm64)
struct VMConfigurationStorageDevicesView: View {
    @Environment(VMConfigurationViewStateObject.self) var configData
    @State private var showingEditView = false
    
    
    var body: some View {
        content
            .sheet(isPresented: $showingEditView) {
                VMConfigurationStorageDevicesEditView()
            }
    }
    
    var content: some View {
        LabeledContent("Storage") {
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(configData.storageDevices) { item in
                    Label(item.data.description, systemImage: item.data.type == .Block ? "internaldrive" : "opticaldiscdrive")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Manage Storage…", systemImage: "slider.horizontal.3") { showingEditView = true }
                    .accessibilityHint("Add or remove virtual disks and installation media")
            }
        }
    }
}

struct VMConfigurationStorageDevicesView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationStorageDevicesView()
            .environment(VMConfigurationViewStateObject())
    }
}


#endif
