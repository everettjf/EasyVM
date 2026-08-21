//
//  VMConfigurationStorageDevicesEditView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/30.
//

import SwiftUI

#if arch(arm64)
struct VMConfigurationStorageDevicesEditView: View {
    @Environment(VMConfigurationViewStateObject.self) var configData
    
    @Environment(\.presentationMode) var presentationMode
    
    
    @State private var inputType: VMModelFieldStorageDevice.DeviceType = .USB
    @State private var inputFormat: VMDiskImageFormat = .asif
    @State private var inputSize: UInt64 = 64 * 1024 * 1024 * 1024
    @State private var inputPath = ""
    
    
    var body: some View {
        VStack(alignment: .leading) {
            Form {
                Section("Add Storage Device") {
                    Picker("Type", selection: $inputType) {
                        ForEach(VMModelFieldStorageDevice.DeviceType.allCases) { item in
                            Text(item.rawValue)
                        }
                    }
                    
                    if inputType == .Block {
                        Picker("Disk Format", selection: $inputFormat) {
                            ForEach(VMDiskImageFormat.allCases) { format in
                                Text(format.rawValue.uppercased()).tag(format)
                            }
                        }
                        TextField("Block Size", value: $inputSize, format: .number)
                    } else {
                        TextField("ISO Image Path", text: $inputPath)
                            .padding(.leading, 0)
                        HStack {
                            Spacer()
                            Button {
                                MacKitUtil.selectFile(title: "Choose *.iso file") { path in
                                    guard let path = path else {
                                        return
                                    }
                                    inputPath = path.path(percentEncoded: false)
                                }
                            } label: {
                                Image(systemName: "folder")
                                Text("Select")
                            }
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
                    List (configData.storageDevices) { item in
                        HStack {
                            Text("\(String(describing: item.data))")
                            Spacer()
                            Button {
                                // remove
                                if configData.storageDevices.count == 1 {
                                    return
                                }
                                if let found = configData.storageDevices.firstIndex(where: {$0.id == item.id}) {
                                    configData.storageDevices.remove(at: found)
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
        if inputType == .USB {
            if inputPath.isEmpty {
                return
            }
        }
        
        let path = inputType == .Block ? "Disk-\(UUID().uuidString).\(inputFormat.fileExtension)" : inputPath
        let device = VMModelFieldStorageDevice(type: inputType, size: inputSize, imagePath: path, format: inputFormat)
        
        configData.storageDevices.append(VMModelFieldStorageDeviceItemModel(data: device))
    }
}

struct VMConfigurationStorageDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationStorageDevicesEditView()
            .environment(VMConfigurationViewStateObject())
            .frame(height: 600)
    }
}


#endif
