//
//  VMConfigurationPointingDevicesView.swift
//  EZVM
//
//  Created by everettjf on 2022/9/30.
//

import SwiftUI

#if arch(arm64)
struct VMConfigurationPointingDevicesView: View {
    @Environment(VMConfigurationViewStateObject.self) var configData
    @State private var showingEditView = false
    
    var body: some View {
        content
            .sheet(isPresented: $showingEditView) {
                VMConfigurationPointingDevicesEditView()
            }
    }
    var content: some View {
        
        LabeledContent("Pointer") {
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(configData.pointingDevices) { item in
                    Label(item.data.description, systemImage: "cursorarrow.motionlines")
                }
                Button("Manage Pointer…", systemImage: "slider.horizontal.3") { showingEditView = true }
                    .accessibilityHint("Configure the guest pointing device")
            }
        }
    }
}

struct VMConfigurationPointingDevicesView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationPointingDevicesView()
            .environment(VMConfigurationViewStateObject())
    }
}


#endif
