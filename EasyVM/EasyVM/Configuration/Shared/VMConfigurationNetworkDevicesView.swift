//
//  VMConfigurationNetworkView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/30.
//

import SwiftUI

struct VMConfigurationNetworkDevicesView: View {
    @EnvironmentObject var configData: VMConfigurationViewStateObject
    @State var showingEditView = false
    
    var body: some View {
        content
            .sheet(isPresented: $showingEditView) {
                VMConfigurationNetworkDevicesEditView()
            }
    }
    var content: some View {
        
        LabeledContent("Network Devices") {
            VStack(alignment: .trailing) {
                List(configData.networkDevices) { item in
                    HStack {
                        Spacer()
                        Text("\(String(describing: item.data))")
                    }
                }
                .frame(width:400)
                
                VStack {
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

struct VMConfigurationNetworkView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationNetworkDevicesView()
            .environmentObject(VMConfigurationViewStateObject())
    }
}
