//
//  VMConfigurationNetworkView.swift
//  EZVM
//
//  Created by everettjf on 2022/9/30.
//

import SwiftUI

#if arch(arm64)
struct VMConfigurationNetworkDevicesView: View {
    @Environment(VMConfigurationViewStateObject.self) var configData
    @State private var showingEditView = false
    
    var body: some View {
        content
            .sheet(isPresented: $showingEditView) {
                VMConfigurationNetworkDevicesEditView()
            }
    }
    var content: some View {
        
        LabeledContent("Network") {
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(configData.networkDevices) { item in
                    VStack(alignment: .trailing, spacing: 2) {
                        Label(item.data.type.shortDisplayName, systemImage: item.data.type.symbolName)
                            .fontWeight(.medium)
                        Text(item.data.configurationSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
                if configData.networkDevices.isEmpty {
                    Label("No connection", systemImage: "network.slash")
                        .foregroundStyle(.secondary)
                }
                Button("Manage Network…", systemImage: "slider.horizontal.3") { showingEditView = true }
                    .accessibilityHint("Choose NAT or VMNet networking")
            }
        }
        
    }
}

struct VMConfigurationNetworkView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationNetworkDevicesView()
            .environment(VMConfigurationViewStateObject())
    }
}


#endif
