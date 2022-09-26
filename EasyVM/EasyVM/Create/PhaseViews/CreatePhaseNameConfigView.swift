//
//  CreatePhaseNameConfigView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI


class CreatePhaseNameConfigViewHandler: CreateStepperGuidePhaseHandler {
    func verifyForm(formData: CreateFormModel) -> CreateStepperGuidePhaseVerifyResult {
        if formData.name.isEmpty {
            return .failure("Name is empty")
        }
        return .success
    }
}

struct CreatePhaseNameConfigView: View {
    @EnvironmentObject var formData: CreateFormModel
    
    var body: some View {
        VStack {
            Text("Choose the location for virtual machine:")
                .font(.title3)
                .padding(.all)
            
            Form {
                
                Section ("Basic") {
                    TextField("Name", text: $formData.name).lineLimit(1)
                    
                    TextField("Description", text:$formData.remark).lineLimit(3, reservesSpace: true)
                }
                
            }
            .formStyle(.grouped)
        }
    }
}

struct CreatePhaseNameConfigView_Previews: PreviewProvider {
    static var previews: some View {
        let formData = CreateFormModel()
        CreatePhaseNameConfigView()
            .environmentObject(formData)
    }
}
