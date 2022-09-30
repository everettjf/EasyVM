//
//  VMConfigurationView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI


struct VMConfigurationView: View {
    
    var body: some View {
        Form {
            Section ("CPU / Memory / Disk") {
                VMConfigurationCPUView()
                VMConfigurationMemoryView()
                VMConfigurationDiskView()
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
        }
        .formStyle(.grouped)
    }
}

struct VMConfigurationView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationView()
            .frame(width: 700, height:1000)
    }
}
