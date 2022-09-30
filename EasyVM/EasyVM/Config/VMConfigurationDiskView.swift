//
//  VMConfigurationDiskView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/29.
//

import SwiftUI

struct VMConfigurationDiskView: View {
    @EnvironmentObject var configData: VMConfigurationViewStateObject
    
    let _1GB: UInt64 = 1024 * 1024 * 1024
    let maxSize: UInt64 = 256 * 1024 * 1024 * 1024
    let minSize: UInt64 = 8 * 1024 * 1024 * 1024
    
    func increase(_ value: UInt64) {
        if configData.diskSize >= maxSize {
            configData.diskSize = maxSize
            return
        }
        var result = configData.diskSize + value
        if result > maxSize {
            result = maxSize
        }
        configData.diskSize = result
    }
    
    func decrease(_ value: UInt64) {
        if configData.diskSize < minSize {
            configData.diskSize = minSize
            return
        }
        if configData.diskSize < value {
            configData.diskSize = minSize
            return
        }
        var result = configData.diskSize - value
        if result < minSize {
            result = minSize
        }
        configData.diskSize = result
    }
    
    var body: some View {
        LabeledContent("Disk Size") {
            VStack(alignment: .trailing) {
                TextField("", value: $configData.diskSize, format: .number)

                HStack {
                    Text("MAX:\(maxSize / _1GB)GB MIN:\(minSize / _1GB)GB")
                    Button("32GB") {configData.diskSize = 32 * _1GB}
                    Button("64GB") {configData.diskSize = 64 * _1GB}
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
            .environmentObject(VMConfigurationViewStateObject())
    }
}
