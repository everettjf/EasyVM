//
//  VMConfigurationGraphicsDevicesView.swift
//  EZVM
//
//  Created by everettjf on 2022/9/29.
//

import SwiftUI

#if arch(arm64)
struct VMConfigurationGraphicDevicesView: View {
    
    @Environment(VMConfigurationViewStateObject.self) var configData
    
    @State private var showingEditView = false
    
    var body: some View {
        content
            .sheet(isPresented: $showingEditView) {
                VMConfigurationGraphicDevicesEditView()
            }
    }
    
    var content: some View {
        
        LabeledContent("Display") {
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(configData.graphicDevices) { item in
                    Label(item.data.description, systemImage: "display")
                }
                Button("Manage Displays…", systemImage: "slider.horizontal.3") { showingEditView = true }
                    .accessibilityHint("Configure guest display type and resolution")
            }
        }
    }
}

struct VMConfigurationGraphicDevicesView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            Section("Section") {
                VMConfigurationGraphicDevicesView()
            }
        }
        .environment(VMConfigurationViewStateObject())
    }
}


#endif
