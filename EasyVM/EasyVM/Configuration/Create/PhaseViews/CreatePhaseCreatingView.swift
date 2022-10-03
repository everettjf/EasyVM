//
//  CreatePhaseCreatingView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI


class CreatePhaseCreatingViewHandler: VMCreateStepperGuidePhaseHandler {
    
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        return .success
    }
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
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
        let result = await creator.create(model: vmModel, progress: { progressInfo in
            switch progressInfo {
            case .info(let log):
                print("LOG INFO : \(log)")
                context.formData.addLog(log)
            case .error(let log):
                print("LOG ERROR : \(log)")
                context.formData.addLog("❌ ERROR : \(log)")
            case .progress(let percent):
                print("Progress : \(percent)")
                context.formData.addLog("- Progress : \(String(format: "%.0f", percent * 100))%")
                context.formData.changeProgress(percent)
            }
        })
        print("!! End create virtual machine")
        
        switch result {
        case .failure(let error):
            print("Failed to create : \(error)")
        case .success:
            DispatchQueue.main.async {
                context.formData.disablePreviousButton = true
            }
        }
        
        return result
    }
}


struct CreatePhaseCreatingView: View {
    @EnvironmentObject var formData: VMCreateViewStateObject
    
    var body: some View {
        VStack {
            Text("Creating Virtual Machine")
                .font(.title3)
                .padding(.all)
            
            HStack {
                Text("\(String(format: "%.0f", 100 * formData.installingProgress))%")
                    .font(.caption)
                ProgressView(value: 100 * formData.installingProgress, total: 100)
            }
            
            List {
                ForEach(formData.logs) { item in
                    HStack {
                        Text(item.time)
                        Text(item.log)
                            .lineLimit(0)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
        }
    }
}

struct CreatePhaseCreatingView_Previews: PreviewProvider {
    static var previews: some View {
        let formData = VMCreateViewStateObject()
        CreatePhaseCreatingView()
            .environmentObject(formData)
    }
}
