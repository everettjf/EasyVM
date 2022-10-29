//
//  VMConfigurationNetworkDevicesEditView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/30.
//

import SwiftUI

#if arch(arm64)
struct VMConfigurationNetworkDevicesEditView: View {
    @EnvironmentObject var configData: VMConfigurationViewStateObject
    
    @Environment(\.presentationMode) var presentationMode
    
    @State var inputType: VMModelFieldNetworkDevice.DeviceType = .NAT

    
    var body: some View {
        VStack(alignment: .leading) {
            Form {
                Section("Add Network Device") {
                    Picker("Type", selection: $inputType) {
                        ForEach(VMModelFieldNetworkDevice.DeviceType.allCases) { item in
                            Text(item.rawValue)
                        }
                    }
                    
                    HStack {
                        Spacer()
                        
                        Button {
                            addDevice()
                        } label: {
                            Image(systemName: "plus.app")
                            Text("Add")
                        }
                    }
                }
                Section("Current Devices") {
                    List (configData.networkDevices) { item in
                        HStack {
                            Text("\(String(describing: item.data))")
                            Spacer()
                            Button {
                                // remove
                                if let found = configData.networkDevices.firstIndex(where: {$0.id == item.id}) {
                                    configData.networkDevices.remove(at: found)
                                }
                                
                            } label: {
                                Image(systemName: "delete.left")
                            }
                        }
                    }
                    .frame(minHeight: 100)
                }
            }
            .formStyle(.grouped)
            
            
            HStack {
                Spacer()
                Button {
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    Text("Close")
                }
            }
            .padding()
        }
    }
    
    
    func addDevice() {
        let device = VMModelFieldNetworkDevice(type: inputType)
        configData.networkDevices.append(VMModelFieldNetworkDeviceItemModel(data: device))
    }
}

struct VMConfigurationNetworkDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationNetworkDevicesEditView()
            .environmentObject(VMConfigurationViewStateObject())
            .frame(height: 600)
    }
}


#endif
