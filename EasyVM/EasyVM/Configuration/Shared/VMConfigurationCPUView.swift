//
//  VMConfigurationCPUView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/29.
//

import SwiftUI

#if arch(arm64)

struct VMConfigurationCPUView: View {
    @EnvironmentObject var configData: VMConfigurationViewStateObject
    
    var body: some View {
        LabeledContent("CPU Count") {
            VStack (alignment: .trailing) {
                Stepper {
                    Text("\(configData.cpuCount)")
                } onIncrement: {
                    let max = VMModelFieldCPU.maxCount()
                    var value = configData.cpuCount + 1
                    if value > max {
                        value = max
                    }
                    configData.cpuCount = value
                } onDecrement: {
                    let min = VMModelFieldCPU.minCount()
                    var value = configData.cpuCount - 1
                    if value < min {
                        value = min
                    }
                    configData.cpuCount = value
                }
                
                Text("MAX: \(VMModelFieldCPU.maxCount()) MIN: \(VMModelFieldCPU.minCount())")
            }
        }
    }
}


struct VMConfigurationCPUView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationCPUView()
            .environmentObject(VMConfigurationViewStateObject())
    }
}


#endif
