//
//  VMConfigurationPointingDevicesEditView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/30.
//

import SwiftUI

struct VMConfigurationPointingDevicesEditView: View {
    
    @EnvironmentObject var state: VMConfigurationViewState
    
    @Environment(\.presentationMode) var presentationMode
    
    @State var inputType: VMModelFieldPointingDevice.DeviceType = .USBScreenCoordinatePointing

    
    var body: some View {
        VStack(alignment: .leading) {
            Form {
                Section("Add Pointing Device") {
                    Picker("Type", selection: $inputType) {
                        ForEach(VMModelFieldPointingDevice.DeviceType.allCases) { item in
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
                    List (state.pointingDevices) { item in
                        HStack {
                            Text("\(String(describing: item.data))")
                            Spacer()
                            Button {
                                // remove
                                if state.pointingDevices.count == 1 {
                                    return
                                }
                                if let found = state.pointingDevices.firstIndex(where: {$0.id == item.id}) {
                                    state.pointingDevices.remove(at: found)
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
        let device = VMModelFieldPointingDevice(type: inputType)
        state.pointingDevices.append(VMModelFieldPointingDeviceItemModel(data: device))
    }
}

struct VMConfigurationPointingDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationPointingDevicesEditView()
            .environmentObject(VMConfigurationViewState())
            .frame(height: 600)
    }
}
