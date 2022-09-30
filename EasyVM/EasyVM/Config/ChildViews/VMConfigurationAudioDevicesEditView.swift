//
//  VMConfigurationAudioDevicesEditView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/30.
//

import SwiftUI

struct VMConfigurationAudioDevicesEditView: View {
    @EnvironmentObject var configData: VMConfigurationViewStateObject
    
    @Environment(\.presentationMode) var presentationMode
    
    @State var inputType: VMModelFieldAudioDevice.DeviceType = .InputStream
    
    var body: some View {
        VStack(alignment: .leading) {
            Form {
                Section("Add Audio Device") {
                    Picker("Type", selection: $inputType) {
                        ForEach(VMModelFieldAudioDevice.DeviceType.allCases) { item in
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
                    List (configData.audioDevices) { item in
                        HStack {
                            Text("\(String(describing: item.data))")
                            Spacer()
                            Button {
                                // remove
                                if let found = configData.audioDevices.firstIndex(where: {$0.id == item.id}) {
                                    configData.audioDevices.remove(at: found)
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
        let device = VMModelFieldAudioDevice(type: inputType)
        configData.audioDevices.append(VMModelFieldAudioDeviceItemModel(data: device))
    }
}

struct VMConfigurationAudioDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationAudioDevicesEditView()
            .environmentObject(VMConfigurationViewStateObject())
            .frame(height: 600)
    }
}
