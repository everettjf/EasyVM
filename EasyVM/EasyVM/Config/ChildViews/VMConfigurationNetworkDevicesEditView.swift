//
//  VMConfigurationNetworkDevicesEditView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/30.
//

import SwiftUI

struct VMConfigurationNetworkDevicesEditView: View {
    @EnvironmentObject var state: VMConfigurationViewState
    
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
                    List (state.networkDevices) { item in
                        HStack {
                            Text("\(String(describing: item.data))")
                            Spacer()
                            Button {
                                // remove
                                if state.networkDevices.count == 1 {
                                    return
                                }
                                if let found = state.networkDevices.firstIndex(where: {$0.id == item.id}) {
                                    state.networkDevices.remove(at: found)
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
        state.networkDevices.append(VMModelFieldNetworkDeviceItemModel(data: device))
    }
}

struct VMConfigurationNetworkDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationNetworkDevicesEditView()
            .environmentObject(VMConfigurationViewState())
            .frame(height: 600)
    }
}
