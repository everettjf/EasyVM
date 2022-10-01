//
//  CreatePhaseChooseStorageDirectoryView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

class CreatePhaseSaveDirectoryViewHandler: CreateStepperGuidePhaseHandler {
    func verifyForm(context: CreateStepperGuidePhaseContext) -> VMOSResultVoid {
        if context.formData.rootPath.isEmpty {
            return .failure("Directory can not be empty")
        }
        
        if FileManager.default.fileExists(atPath: context.formData.rootPath) {
            return .failure("Directory already existed : \(context.formData.rootPath)")
        }
        
        return .success
    }
    func onStepMovedIn(context: CreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        return .success
    }
}

struct CreatePhaseSaveDirectoryView: View {
    @EnvironmentObject var formData: CreateFormStateObject
    @EnvironmentObject var configData: VMConfigurationViewStateObject
    
    
    var body: some View {
        
        VStack {
            Text("Choose the location for virtual machine:")
                .font(.title3)
                .padding(.all)
            
            Form {
                
                Section("Location") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Select where machine files save :")
                            Spacer()
                            Text(formData.rootPath)
                                .lineLimit(4)
                        }
                        
                        HStack {
                            Spacer()
                            Button {
                                MacKitUtil.selectDirectory(title: "Select a direcotry") { path in
                                    print("directory = \(String(describing: path))")
                                    guard let path = path else {
                                        return
                                    }
                                    let vmDir = path.appending(path: configData.name)
                                    self.formData.rootPath = vmDir.path(percentEncoded: false)
                                }
                            } label: {
                                Image(systemName: "folder.badge.plus")
                                Text("Select")
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

struct CreatePhaseSaveDirectoryView_Previews: PreviewProvider {
    static var previews: some View {
        let formData = CreateFormStateObject()
        CreatePhaseSaveDirectoryView()
            .environmentObject(formData)
    }
}
