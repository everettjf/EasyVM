//
//  VMConfigurationDiskView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/29.
//

import SwiftUI

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

struct VMConfigurationDiskView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationDiskView()
            .environmentObject(VMConfigurationViewState())
    }
}
