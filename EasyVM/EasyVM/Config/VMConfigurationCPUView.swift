//
//  VMConfigurationCPUView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/29.
//

import SwiftUI


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


struct VMConfigurationCPUView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationCPUView()
            .environmentObject(VMConfigurationViewState())
    }
}
