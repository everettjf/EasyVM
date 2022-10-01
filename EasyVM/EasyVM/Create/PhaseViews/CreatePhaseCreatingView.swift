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
        let rootPath = URL(filePath:context.formData.rootPath)
        let imagePath = URL(filePath:context.formData.imagePath)
        print("root path : \(rootPath)")
        print("image path : \(rootPath)")
        
        let configModel = context.configData.getConfigModel()
        let vmModel = VMModel(rootPath: rootPath, imagePath: imagePath, config: configModel)
        
        // create vm from vmmodel
        print("!! Start create virtual machine")
        let creator = VMOSCreateFactory.getCreator(configModel.type)
        let result = await creator.create(vmModel: vmModel)
        print("!! End create virtual machine")
        
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
