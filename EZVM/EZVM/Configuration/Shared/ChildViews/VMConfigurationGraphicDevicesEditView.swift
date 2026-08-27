//
//  VMConfigurationGraphicDevicesEditView.swift
//  EZVM
//
//  Created by everettjf on 2022/9/29.
//

import SwiftUI

#if arch(arm64)
struct VMConfigurationGraphicDevicesEditView: View {
    @Environment(VMConfigurationViewStateObject.self) var configData
    
    @Environment(\.presentationMode) var presentationMode
    
    
    @State private var inputType: VMModelFieldGraphicDevice.DeviceType = .Mac
    @State private var inputWidth = 1920
    @State private var inputHeight = 1200
    @State private var inputPixelsPerInch = 80
    
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
            .environment(VMConfigurationViewStateObject())
            .frame(height: 600)
    }
}


#endif
