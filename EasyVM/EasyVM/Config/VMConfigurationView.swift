//
//  VMConfigurationView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI



struct VMConfigurationView: View {
    @ObservedObject var state: VMConfigurationViewState
    
    init(location: VMLocationModel) {
        self.state = VMConfigurationViewState(location: location)
    }
    
    var body: some View {
        content
            .environmentObject(state)
    }
    
    var content: some View {
        Form {
            Section ("CPU / Memory / Disk") {
                VMConfigurationCPUView()
                VMConfigurationMemoryView()
                VMConfigurationDiskView()
            }
            
            Section ("Display / Storage / Network") {
                VMConfigurationGraphicDevicesView()
                VMConfigurationStorageDevicesView()
                
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
                
                
            }
            Section ("Control / Audio") {
                    
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
        VMConfigurationView(location: VMLocationModel(root: "", image: ""))
            .frame(width: 700, height:1000)
    }
}
