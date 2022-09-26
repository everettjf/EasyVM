//
//  CreatePhaseChooseStorageDirectoryView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

class CreatePhaseSaveDirectoryViewHandler: CreateStepperGuidePhaseHandler {
    func verifyForm(formData: CreateFormModel) -> CreateStepperGuidePhaseVerifyResult {
        if formData.saveDirectory.isEmpty {
            return .failure("Directory can not be empty")
        }
        return .success
    }
}

struct CreatePhaseSaveDirectoryView: View {
    @EnvironmentObject var formData: CreateFormModel
    
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
                            Text(formData.saveDirectory)
                                .lineLimit(4)
                        }
                        
                        HStack {
                            Spacer()
                            Button {
                                MacKitUtil.selectDirectory(title: "Select a direcotry") { path in
                                    print("directory = \(String(describing: path))")
                                    if let path = path {
                                        self.formData.saveDirectory = path.absoluteString
                                    }
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
        let formData = CreateFormModel()
        CreatePhaseSaveDirectoryView()
            .environmentObject(formData)
    }
}
