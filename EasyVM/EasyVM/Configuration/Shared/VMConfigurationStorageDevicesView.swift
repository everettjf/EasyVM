//
//  VMConfigurationStorageDevicesView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/29.
//

import SwiftUI

struct VMConfigurationStorageDevicesView: View {
    @EnvironmentObject var configData: VMConfigurationViewStateObject
    @State var showingEditView = false
    
    
    var body: some View {
        content
            .sheet(isPresented: $showingEditView) {
                VMConfigurationStorageDevicesEditView()
            }
    }
    
    var content: some View {
        LabeledContent("Storage Devices") {
            VStack(alignment: .trailing) {
                List(configData.storageDevices) { item in
                    HStack {
                        Spacer()
                        Text("\(String(describing: item.data))")
                    }
                }
                .frame(width:400)
                
                HStack {
                    Spacer()
                    Button {
                        showingEditView.toggle()
                    } label: {
                        Image(systemName: "slider.vertical.3")
                    }
                    
                }
            }
        }
    }
}

struct VMConfigurationStorageDevicesView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationStorageDevicesView()
            .environmentObject(VMConfigurationViewStateObject())
    }
}
