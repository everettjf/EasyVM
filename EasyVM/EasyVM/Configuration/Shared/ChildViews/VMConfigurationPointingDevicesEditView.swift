//
//  VMConfigurationPointingDevicesEditView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/30.
//

import SwiftUI


#if arch(arm64)
struct VMConfigurationPointingDevicesEditView: View {
    
    @EnvironmentObject var configData: VMConfigurationViewStateObject
    
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
                    List (configData.pointingDevices) { item in
                        HStack {
                            Text("\(String(describing: item.data))")
                            Spacer()
                            Button {
                                // remove
                                if configData.pointingDevices.count == 1 {
                                    return
                                }
                                if let found = configData.pointingDevices.firstIndex(where: {$0.id == item.id}) {
                                    configData.pointingDevices.remove(at: found)
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
        configData.pointingDevices.append(VMModelFieldPointingDeviceItemModel(data: device))
    }
}

struct VMConfigurationPointingDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationPointingDevicesEditView()
            .environmentObject(VMConfigurationViewStateObject())
            .frame(height: 600)
    }
}
#endif
