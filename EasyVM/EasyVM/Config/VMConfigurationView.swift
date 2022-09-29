//
//  VMConfigurationView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

class VMConfigurationViewState: ObservableObject {
    @Published var cpuCount: Int = 1
    @Published var memorySize: UInt64 = 1024 * 1024 * 1024 * 2
    @Published var diskSize: UInt64 = 1024 * 1024 * 1024 * 64
    
    
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
                
                Text("MAX: \(VMModelFieldCPU.maxCount()) MIN: \(VMModelFieldCPU.minCount())")
            }
        }
    }
}

struct VMConfigurationMemoryView: View {
    @EnvironmentObject var state: VMConfigurationViewState
    
    let _1GB: UInt64 = 1024 * 1024 * 1024
    let maxMemory = VMModelFieldMemory.maxSize()
    let minMemory = VMModelFieldMemory.minSize()
 
    func increase(_ value: UInt64) {
        if state.memorySize >= maxMemory {
            state.memorySize = maxMemory
            return
        }
        var result = state.memorySize + value
        if result > maxMemory {
            result = maxMemory
        }
        state.memorySize = result
    }
    
    func decrease(_ value: UInt64) {
        if state.memorySize < minMemory {
            state.memorySize = minMemory
            return
        }
        if state.memorySize < value {
            state.memorySize = minMemory
            return
        }
        var result = state.memorySize - value
        if result < minMemory {
            result = minMemory
        }
        state.memorySize = result
    }
    
    var body: some View {
        LabeledContent("Memory Size") {
            VStack(alignment: .trailing) {
                TextField("", value: $state.memorySize, format: .number)

                HStack {
                    Text("MAX:\(maxMemory / _1GB)GB MIN:\(minMemory / _1GB)GB")
                    Button("2GB") {state.memorySize = 2 * _1GB}
                    Button("6GB") {state.memorySize = 6 * _1GB}
                    Button("+1GB") {increase(_1GB)}
                    Button("-1GB") {decrease(_1GB)}
                }
            }
            .frame(minWidth: 360)
            .padding(.all, 0)
        }

    }
}


struct VMConfigurationDiskView: View {
    @EnvironmentObject var state: VMConfigurationViewState
    
    let _1GB: UInt64 = 1024 * 1024 * 1024
    let maxSize: UInt64 = 256 * 1024 * 1024 * 1024
    let minSize: UInt64 = 8 * 1024 * 1024 * 1024
    
    func increase(_ value: UInt64) {
        if state.diskSize >= maxSize {
            state.diskSize = maxSize
            return
        }
        var result = state.diskSize + value
        if result > maxSize {
            result = maxSize
        }
        state.diskSize = result
    }
    
    func decrease(_ value: UInt64) {
        if state.diskSize < minSize {
            state.diskSize = minSize
            return
        }
        if state.diskSize < value {
            state.diskSize = minSize
            return
        }
        var result = state.diskSize - value
        if result < minSize {
            result = minSize
        }
        state.diskSize = result
    }
    
    var body: some View {
        LabeledContent("Disk Size") {
            VStack(alignment: .trailing) {
                TextField("", value: $state.diskSize, format: .number)

                HStack {
                    Text("MAX:\(maxSize / _1GB)GB MIN:\(minSize / _1GB)GB")
                    Button("32GB") {state.diskSize = 32 * _1GB}
                    Button("64GB") {state.diskSize = 64 * _1GB}
                    Button("+8GB") {increase(8 * _1GB)}
                    Button("-8GB") {decrease(8 * _1GB)}
                }
            }
            .frame(minWidth: 400)
            .padding(.all, 0)
        }

    }
}

struct VMConfigurationView: View {
    @ObservedObject var state: VMConfigurationViewState
    
    init() {
        self.state = VMConfigurationViewState()
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
        VMConfigurationView()
            .frame(width: 700, height:1000)
    }
}
