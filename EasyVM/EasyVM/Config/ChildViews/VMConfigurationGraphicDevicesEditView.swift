//
//  VMConfigurationGraphicDevicesEditView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/29.
//

import SwiftUI

struct VMConfigurationGraphicDevicesEditView: View {
    @EnvironmentObject var configData: VMConfigurationViewStateObject
    
    @Environment(\.presentationMode) var presentationMode
    
    
    @State var inputType: VMModelFieldGraphicDevice.DeviceType = .Mac
    @State var inputWidth: Int = 1920
    @State var inputHeight: Int = 1200
    @State var inputPixelsPerInch: Int = 80
    
    var body: some View {
        VStack(alignment: .leading) {
            
            Form {
                
                Section("Add Graphic Device") {
                    Picker("Type", selection: $inputType) {
                        ForEach(VMModelFieldGraphicDevice.DeviceType.allCases) { item in
                            Text(item.rawValue)
                        }
                    }
                    TextField("Width", value: $inputWidth, format: .number)
                    TextField("Height", value: $inputHeight, format: .number)
                    if inputType == .Mac {
                        TextField("Pixels PerInch", value: $inputPixelsPerInch, format: .number)
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
                    List (configData.graphicDevices) { item in
                        HStack {
                            Text("\(String(describing: item.data))")
                            Spacer()
                            Button {
                                // remove
                                if configData.graphicDevices.count == 1 {
                                    return
                                }
                                if let found = configData.graphicDevices.firstIndex(where: {$0.id == item.id}) {
                                    configData.graphicDevices.remove(at: found)
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
        let device = VMModelFieldGraphicDevice(type: inputType, width: inputWidth, height: inputHeight, pixelsPerInch: inputPixelsPerInch)
        
        configData.graphicDevices.append(VMModelFieldGraphicDeviceItemModel(data: device))
    }
}

struct VMConfigurationGraphicDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationGraphicDevicesEditView()
            .environmentObject(VMConfigurationViewStateObject())
            .frame(height: 600)
    }
}
