//
//  VMConfigurationMemoryView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/29.
//

import SwiftUI

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

struct VMConfigurationMemoryView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationMemoryView()
            .environmentObject(VMConfigurationViewState())
    }
}
