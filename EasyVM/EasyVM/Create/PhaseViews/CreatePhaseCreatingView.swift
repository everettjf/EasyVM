//
//  CreatePhaseCreatingView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI


class CreatePhaseCreatingViewHandler: CreateStepperGuidePhaseHandler {
    func verifyForm(formData: CreateFormModel) -> CreateStepperGuidePhaseVerifyResult {
        return .success
    }
}


struct CreatePhaseCreatingView: View {
    @EnvironmentObject var formData: CreateFormModel
    var body: some View {
        
        VStack {
            Text("Creating")
                .font(.title3)
                .padding(.all)
            ProgressView(value: 250, total: 1000)
            
            List{
                Text("Creating...").font(.caption)
                Text("Creating...").font(.caption)
                Text("Creating...").font(.caption)
                Text("Creating...").font(.caption)
                Text("Creating...").font(.caption)
                Text("Creating...").font(.caption)
                Text("Creating...").font(.caption)
            }
        }
    }
}

struct CreatePhaseCreatingView_Previews: PreviewProvider {
    static var previews: some View {
        let formData = CreateFormModel()
        CreatePhaseCreatingView()
            .environmentObject(formData)
    }
}
