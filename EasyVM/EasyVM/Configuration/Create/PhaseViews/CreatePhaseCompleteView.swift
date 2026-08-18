//
//  CreatePhaseCompleteView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI



#if arch(arm64)
class CreatePhaseCompleteViewHandler: VMCreateStepperGuidePhaseHandler {

    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        return .success
    }
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        return .success
    }
}


struct CreatePhaseCompleteView: View {
    @EnvironmentObject var formData: VMCreateViewStateObject
    @EnvironmentObject var configData: VMConfigurationViewStateObject

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("\(configData.name) is ready")
                .font(.title2)

            Text(formData.rootPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 16) {
                Button {
                    let rootPath = URL(filePath: formData.rootPath)
                    openWindow(id: "start-machine", value: rootPath)
                    dismiss()
                } label: {
                    Image(systemName: "play.fill")
                    Text("Run Virtual Machine")
                }
                .keyboardShortcut(.defaultAction)

                Button {
                    MacKitUtil.revealInFinder(formData.rootPath)
                } label: {
                    Image(systemName: "folder")
                    Text("Reveal in Finder")
                }
            }
            .padding(.top)

            Spacer()
        }
    }
}

struct CreatePhaseCompleteView_Previews: PreviewProvider {
    static let formData = VMCreateViewStateObject()
    static let configData = VMConfigurationViewStateObject()

    static var previews: some View {
        CreatePhaseCompleteView()
            .environmentObject(formData)
            .environmentObject(configData)
    }
}


#endif
