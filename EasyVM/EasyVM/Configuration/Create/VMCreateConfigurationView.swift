//
//  VMConfigurationView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI


struct VMCreateConfigurationView: View {
    
    var body: some View {
        Form {
            Section ("CPU / Memory") {
                VMConfigurationCPUView()
                VMConfigurationMemoryView()
            }
            
            Section ("Display / Storage / Network") {
                VMConfigurationGraphicDevicesView()
                VMConfigurationStorageDevicesView()
                VMConfigurationNetworkDevicesView()
                
            }
            Section ("Pointing / Audio") {
                VMConfigurationPointingDevicesView()
                VMConfigurationAudioDevicesView()
            }
            Section("Sharing Directory") {
                VMConfigurationDirectorySharingDevicesView()
            }
        }
        .formStyle(.grouped)
    }
}

struct VMConfigurationView_Previews: PreviewProvider {
    static var previews: some View {
        VMCreateConfigurationView()
            .frame(width: 700, height:1000)
    }
}
