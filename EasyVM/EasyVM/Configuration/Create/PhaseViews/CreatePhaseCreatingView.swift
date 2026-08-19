//
//  CreatePhaseCreatingView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

#if arch(arm64)

class CreatePhaseCreatingViewHandler: VMCreateStepperGuidePhaseHandler {

    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        return .success
    }
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        // fill from form
        let rootPath = URL(filePath:context.formData.rootPath)
        let imagePath = URL(filePath:context.formData.imagePath)
        print("root path : \(rootPath)")
        print("image path : \(imagePath)")

        let stateModel = VMStateModel(imagePath: imagePath)
        let configModel = context.configData.getConfigModel()
        let vmModel = VMModel(rootPath: rootPath, state: stateModel, config: configModel)

        // create vm from vmmodel
        print("!! Start create virtual machine")
        context.formData.isCreating = true
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
                context.formData.changeProgress(percent)
            }
        })
        print("!! End create virtual machine")
        context.formData.isCreating = false

        switch result {
        case .failure(let error):
            print("Failed to create : \(error)")
        case .success:
            context.formData.disablePreviousButton = true
            sharedAppConfigManager.addVMPathWithRefresh(url: rootPath)
        }

        return result
    }
}


struct CreatePhaseCreatingView: View {
    @EnvironmentObject var formData: VMCreateViewStateObject

    @State private var showDetails = false

    var body: some View {
        VStack {
            Text("Creating Virtual Machine")
                .font(.title3)
                .padding(.all)

            // current activity headline, so the user does not have to read logs
            HStack {
                if formData.isCreating {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(formData.statusText)
                    .lineLimit(2)
                Spacer()
            }

            HStack {
                Text("\(String(format: "%.0f", 100 * formData.installingProgress))%")
                    .font(.caption)
                ProgressView(value: 100 * formData.installingProgress, total: 100)
            }

            DisclosureGroup("Details", isExpanded: $showDetails) {
                List {
                    ForEach(formData.logs) { item in
                        HStack {
                            Text(item.time)
                                .foregroundStyle(.secondary)
                            Text(item.log)
                                .lineLimit(0)
                                .multilineTextAlignment(.leading)
                        }
                        .font(.caption)
                    }
                }
                .frame(minHeight: 220)
            }

            Spacer()
        }
        .onChange(of: formData.statusText) { newValue in
            // surface the full log as soon as something goes wrong
            if newValue.hasPrefix("❌") {
                showDetails = true
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


#endif
