//
//  VMConfigurationMemoryView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/29.
//

import SwiftUI

struct VMConfigurationMemoryView: View {
    @EnvironmentObject var configData: VMConfigurationViewStateObject
    
    let _1GB: UInt64 = 1024 * 1024 * 1024
    let maxMemory = VMModelFieldMemory.maxSize()
    let minMemory = VMModelFieldMemory.minSize()
 
    func increase(_ value: UInt64) {
        if configData.memorySize >= maxMemory {
            configData.memorySize = maxMemory
            return
        }
        var result = configData.memorySize + value
        if result > maxMemory {
            result = maxMemory
        }
        configData.memorySize = result
    }
    
    func decrease(_ value: UInt64) {
        if configData.memorySize < minMemory {
            configData.memorySize = minMemory
            return
        }
        if configData.memorySize < value {
            configData.memorySize = minMemory
            return
        }
        var result = configData.memorySize - value
        if result < minMemory {
            result = minMemory
        }
        configData.memorySize = result
    }
    
    var body: some View {
        LabeledContent("Memory Size") {
            VStack(alignment: .trailing) {
                TextField("", value: $configData.memorySize, format: .number)

                HStack {
                    Text("MAX:\(maxMemory / _1GB)GB MIN:\(minMemory / _1GB)GB")
                    Button("2GB") {configData.memorySize = 2 * _1GB}
                    Button("6GB") {configData.memorySize = 6 * _1GB}
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
            .environmentObject(VMConfigurationViewStateObject())
    }
}
