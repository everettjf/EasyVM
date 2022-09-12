//
//  VMConfigurationView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

struct VMConfigurationView: View {
    
    @State private var cpuCount: Int = 1
    @State private var memorySize: Int = 1024 * 1024 * 2

    
    var body: some View {
        Form {
            
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

struct VMConfigurationView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationView()
            .frame(height:1000)
    }
}
