//
//  VMConfigurationView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

class VMConfigurationViewState: ObservableObject {
    @Published var cpuCount: Int = 1
    @Published var memorySize: Int = 1024 * 1024 * 2
    
    
    init() {
        self.cpuCount = VMModelFieldCPU.defaultCount()
    }
}

struct VMConfigurationCPUView: View {
    @EnvironmentObject var state: VMConfigurationViewState
    
    
    var body: some View {
        LabeledContent("CPU Count") {
            VStack (alignment: .trailing) {
                Stepper {
                    Text("\(state.cpuCount)")
                } onIncrement: {
                    let max = VMModelFieldCPU.maxCount()
                    var value = state.cpuCount + 1
                    if value > max {
                        value = max
                    }
                    state.cpuCount = value
                } onDecrement: {
                    let min = VMModelFieldCPU.minCount()
                    var value = state.cpuCount - 1
                    if value < min {
                        value = min
                    }
                    state.cpuCount = value
                }
                
                HStack {
                    Text("MAX: \(VMModelFieldCPU.maxCount())")
                    Text("MIN: \(VMModelFieldCPU.minCount())")
                }
            }
        }
    }
}

struct VMConfigurationView: View {
    @ObservedObject var state: VMConfigurationViewState
    
    init() {
        self.state = VMConfigurationViewState()
    }
    
    func getCPUTitle() -> String {
        
        let max = VMModelFieldCPU.maxCount()
        let min = VMModelFieldCPU.minCount()
        
        return "CPU Count (MAX:\(max),MIN:\(min))"
    }

    var body: some View {
        content
            .environmentObject(state)
    }
    
    var content: some View {
        Form {
            
            Section ("Machine Configuration") {
                VMConfigurationCPUView()
                
                TextField("Memory Size", value: $state.memorySize, format: .number)
                TextField("Disk Size", value: $state.memorySize, format: .number)
                
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
