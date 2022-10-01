//
//  CreatePhaseCreatingView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI


class CreatePhaseCreatingViewHandler: CreateStepperGuidePhaseHandler {
    
    func verifyForm(context: CreateStepperGuidePhaseContext) -> VMOSResultVoid {
        return .success
    }
    func onStepMovedIn(context: CreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        // fill from form
        guard let rootPath = URL(string:context.formData.saveDirectory) else {
            return .failure("invalid save directory")
        }
        guard let imagePath = URL(string:context.formData.imagePath) else {
            return .failure("invalid image path")
        }
        
        let osType = context.formData.osType
        let basicModel = context.formData.getBasicModel()
        let configModel = context.configData.getConfigModel(osType: osType)
        let vmModel = VMModel(rootPath: rootPath, imagePath: imagePath, basic: basicModel, config: configModel)
        
        // create vm from vmmodel
        let creator = VMOSCreateFactory.getCreator(osType)
        let result = await creator.create(vmModel: vmModel)
        
        return result
    }
}


struct CreatePhaseCreatingView: View {
    @EnvironmentObject var formData: CreateFormStateObject
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
        let formData = CreateFormStateObject()
        CreatePhaseCreatingView()
            .environmentObject(formData)
    }
}
