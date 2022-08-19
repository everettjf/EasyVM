//
//  CreateView.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/6.
//

import SwiftUI

struct CreateView: View {
    
    @State private var osType: VMModelOSType = .macOS
    @State private var name: String = "My New Virtual Machine"
    @State private var remark: String = ""
    @State private var vmDirectory: String = ""
    @State private var imagePath: String = ""
    
    @State private var cpuCount: Int = 1
    @State private var memorySize: Int = 1024 * 1024 * 2

    
    var body: some View {
        Form {
            Section ("Location & Image") {
                LabeledContent("Save Directory") {
                    HStack {
                        Text("/Users/everettjf/EasyVirtualMachines")
                        Button {
                            
                        } label: {
                            Image(systemName: "folder.badge.plus")
                        }
                    }
                }
                LabeledContent("Image Path") {
                    HStack {
                        Text("/Users/everettjf/Download/macos-latest.ipsw")
                        Button {
                            
                        } label: {
                            Image(systemName: "doc.badge.plus")
                        }
                    }
                }
            }
            
            Section ("Basic Information") {
                TextField("Name", text: $name).lineLimit(2)
                Picker("OS Type", selection: $osType) {
                    ForEach(VMModelOSType.allCases) { item in
                        Text(item.name).tag(item)
                    }
                }
                .pickerStyle(.inline)
                
                
                TextField("Description", text:$remark).lineLimit(3, reservesSpace: true)
            }
            
            Section ("Machine Configuration") {
                LabeledContent("CPU Count") {
                    Stepper {
                        Text("\(cpuCount)")
                    } onIncrement: {
                        self.cpuCount += 1
                    } onDecrement: {
                        self.cpuCount -= 1
                    }
                    
                }
                
                TextField("Memory Size", value: $memorySize, format: .number)
                TextField("Disk Size", value: $memorySize, format: .number)
                
                LabeledContent("Graphics Devices") {
                    HStack(spacing:0) {
                        List {
                            Text("Virtio 1280 * 720")
                            Text("Virtio 800 * 600")
                            Text("Mac 1280 * 720 (2 PixelsPerInch)")
                            Text("Mac 800 * 600 (2 PixelsPerInch)")
                        }
                        .frame(width:300)
                        
                        VStack {
                            Spacer()
                            Button {
                                
                            } label: {
                                Image(systemName: "plus")
                            }

                        }
                    }
                }
                
                LabeledContent("Storage Devices") {
                    HStack(spacing:0) {
                        List {
                            Text("Block 64GB")
                            Text("USB <path to iso file>")
                        }
                        .frame(width:300)
                        
                        VStack {
                            Spacer()
                            Button {
                                
                            } label: {
                                Image(systemName: "plus")
                            }

                        }
                    }
                }
                LabeledContent("Network Devices") {
                    HStack(spacing:0) {
                        List {
                            Text("NAT")
                            Text("Bridged")
                            Text("FileHandle")
                        }
                        .frame(width:300)
                        
                        VStack {
                            Spacer()
                            Button {
                                
                            } label: {
                                Image(systemName: "plus")
                            }

                        }
                    }
                }
                LabeledContent("Pointing Devices") {
                    HStack(spacing:0) {
                        List {
                            Text("USB Screeen")
                            Text("Mac Trackpad")
                        }
                        .frame(width:300)
                        
                        VStack {
                            Spacer()
                            Button {
                                
                            } label: {
                                Image(systemName: "plus")
                            }

                        }
                    }
                }
                LabeledContent("Keyboard Devices") {
                    HStack(spacing:0) {
                        List {
                            Text("USB")
                        }
                        .frame(width:300)
                        
                        VStack {
                            Spacer()
                            Button {
                                
                            } label: {
                                Image(systemName: "plus")
                            }

                        }
                    }
                }
                LabeledContent("Audio Devices") {
                    HStack(spacing:0) {
                        List {
                            Text("Input Stream")
                            Text("Output Stream")
                        }
                        .frame(width:300)
                        
                        VStack {
                            Spacer()
                            Button {
                                
                            } label: {
                                Image(systemName: "plus")
                            }

                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct CreateView_Previews: PreviewProvider {
    static var previews: some View {
        CreateView()
            .frame(height:1500)
    }
}
