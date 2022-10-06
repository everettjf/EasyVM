//
//  VMConfigurationDirectorySharingDevicesEditView.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/6.
//

import SwiftUI

struct VMConfigurationDirectorySharingDevicesEditView: View {
    @EnvironmentObject var configData: VMConfigurationViewStateObject
    
    @Environment(\.presentationMode) var presentationMode
    
    
    @State private var inputDirectory: String = ""
    @State private var inputName: String = ""
    @State private var inputReadOnly: Bool = false
    
    
    @State private var inputSharingItems: [VMModelFieldDirectorySharingDevice.SharingItem] = []
    @State private var inputTag: String = ""
    @State private var inputAutoMount: Bool = true
    
    
    var body: some View {
        VStack(alignment: .leading) {
            Form {
                Section("Sharing Directory Item") {
                    HStack {
                        Text("Sharing Directory")
                        Spacer()
                        Text(inputDirectory)
                        Button("Select") {
                            MacKitUtil.selectDirectory(title: "Select sharing directory") { path in
                                guard let path = path else {
                                    return
                                }
                                inputDirectory = path.path(percentEncoded: false)
                                inputName = path.lastPathComponent
                            }
                        }
                    }
                    
                    TextField("Sharing Name", text: $inputName)
                    
                    Toggle(isOn: $inputReadOnly) {
                        Text("ReadOnly")
                    }
                    
                    HStack {
                        Spacer()
                        Button {
                            if inputDirectory.isEmpty {
                                return
                            }
                            if inputName.isEmpty {
                                return
                            }
                            let path = URL(filePath: inputDirectory)
                            
                            if let found = inputSharingItems.first(where: {$0.path.path(percentEncoded: false) == inputDirectory}) {
                                print("path already added : \(found)")
                                return
                            }
                            
                            inputSharingItems.append(VMModelFieldDirectorySharingDevice.SharingItem(name: inputName, path: path, readOnly: inputReadOnly))
                        } label: {
                            Text("Confirm")
                        }

                    }
                    
                }
                
                Section("Add Sharing Directory") {
                    LabeledContent("Directories") {
                        List {
                            ForEach(inputSharingItems, id: \.path) { item in
                                HStack {
                                    Text("\(item.description)")
                                    Spacer()
                                    Button {
                                        // remove
                                        if let found = inputSharingItems.firstIndex(where: {$0.path.path(percentEncoded:false) == item.path.path(percentEncoded: false)}) {
                                            inputSharingItems.remove(at: found)
                                        }
                                    } label: {
                                        Image(systemName: "delete.left")
                                    }
                                }
                            }
                        }
                    }
                    
                    if configData.osType == .macOS {
                        Toggle(isOn: $inputAutoMount) {
                            Text("Auto Mount")
                        }
                        if !inputAutoMount {
                            TextField("Tag", text: $inputTag)
                                .padding(.leading, 0)
                        }
                    } else {
                        TextField("Tag", text: $inputTag)
                            .padding(.leading, 0)
                    }
                    
                    HStack {
                        Spacer()
                        Button {
                            
                            if inputSharingItems.isEmpty {
                                return
                            }
                            var finalTag = inputTag;
                            if configData.osType == .macOS && inputAutoMount {
                                finalTag = VMModelFieldDirectorySharingDevice.autoMoundTag
                            }
                            if finalTag.isEmpty {
                                return
                            }
                            print("final tag : \(finalTag)")
                            
                            configData.directorySharingDevices.append(VMModelFieldDirectorySharingDeviceItemModel(data: VMModelFieldDirectorySharingDevice(tag: finalTag, items: inputSharingItems)))
                            
                            // clear
                            inputSharingItems.removeAll()
                            inputName = ""
                            inputDirectory = ""
                            
                        } label: {
                            Text("Add")
                        }

                    }
                }
                
                Section("Current Directory Sharing Devices") {
                    List (configData.directorySharingDevices) { item in
                        HStack {
                            Text("\(String(describing: item.data))")
                            Spacer()
                            Button {
                                // remove
                                if let found = configData.directorySharingDevices.firstIndex(where: {$0.id == item.id}) {
                                    configData.directorySharingDevices.remove(at: found)
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
}

struct VMConfigurationDirectorySharingDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationDirectorySharingDevicesEditView()
            .environmentObject(VMConfigurationViewStateObject())
            .frame(height: 600)
    }
}
