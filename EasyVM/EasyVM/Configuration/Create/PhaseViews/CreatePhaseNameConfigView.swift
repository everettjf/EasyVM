//
//  CreatePhaseNameConfigView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI


#if arch(arm64)
class CreatePhaseNameConfigViewHandler: VMCreateStepperGuidePhaseHandler {
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        if context.configData.name.isEmpty {
            return .failure("Name is empty")
        }
        return .success
    }
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        
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
#endif
