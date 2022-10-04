//
//  CreatePhaseNameConfigView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI


class CreatePhaseNameConfigViewHandler: VMCreateStepperGuidePhaseHandler {
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        if context.configData.name.isEmpty {
            return .failure("Name is empty")
        }
        return .success
    }
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        
        let defaultMacOSName = "Easy Virtual Machine (macOS)"
        let defaultLinuxName = "Easy Virtual Machine (Linux)"
        
        if context.configData.name.isEmpty
            || context.configData.name == defaultMacOSName
            || context.configData.name == defaultLinuxName
        {
            switch context.configData.osType {
            case .macOS:
                DispatchQueue.main.async {
                    context.configData.name = defaultMacOSName
                }
            case .linux:
                DispatchQueue.main.async {
                    context.configData.name = defaultLinuxName
                }
            }
        }
        
        return .success
    }
}

struct CreatePhaseNameConfigView: View {
    @EnvironmentObject var formData: VMCreateViewStateObject
    @EnvironmentObject var configData: VMConfigurationViewStateObject
    
    var body: some View {
        VStack {
            Text("Choose the location for virtual machine:")
                .font(.title3)
                .padding(.all)
            
            Form {
                
                Section ("Basic") {
                    TextField("Name", text: $configData.name).lineLimit(1)
                    
                    TextField("Description", text:$configData.remark).lineLimit(3, reservesSpace: true)
                }
                
            }
            .formStyle(.grouped)
        }
    }
}

struct CreatePhaseNameConfigView_Previews: PreviewProvider {
    static var previews: some View {
        let formData = VMCreateViewStateObject()
        CreatePhaseNameConfigView()
            .environmentObject(formData)
    }
}
