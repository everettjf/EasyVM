//
//  VMConfigurationAudioDevicesView.swift
//  EZVM
//
//  Created by everettjf on 2022/9/30.
//

import SwiftUI

#if arch(arm64)
struct VMConfigurationAudioDevicesView: View {
    @Environment(VMConfigurationViewStateObject.self) var configData
    @State private var showingEditView = false
    
    var body: some View {
        content
            .sheet(isPresented: $showingEditView) {
                VMConfigurationAudioDevicesEditView()
            }
    }
    var content: some View {
        
        LabeledContent("Audio") {
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(configData.audioDevices) { item in
                    Label(item.data.description, systemImage: item.data.type.systemImage)
                }
                Button("Manage Audio…", systemImage: "slider.horizontal.3") { showingEditView = true }
                    .accessibilityHint("Configure guest microphone and speaker access")
            }
        }
    }
}

struct VMConfigurationAudioDevicesView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationAudioDevicesView()
            .environment(VMConfigurationViewStateObject())
    }
}


#endif
