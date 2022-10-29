//
//  CreatePhaseChooseStorageDirectoryView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

#if arch(arm64)
class CreatePhaseSaveDirectoryViewHandler: VMCreateStepperGuidePhaseHandler {
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        if context.formData.rootPath.isEmpty {
            return .failure("Directory can not be empty")
        }
        
        if FileManager.default.fileExists(atPath: context.formData.rootPath) {
            return .failure("Directory already existed : \(context.formData.rootPath)")
        }
        
        return .success
    }
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        DispatchQueue.main.async {
            let lastSaveDirectory = self.readLastDirectory()
            if !lastSaveDirectory.isEmpty {
                let lastSaveURL = URL(filePath: lastSaveDirectory)
                
                let bundleName = "\(context.configData.name).ezvm"
                let vmDir = lastSaveURL.appending(path: bundleName)
                context.formData.rootPath = vmDir.path(percentEncoded: false)
            }
        }
        return .success
    }
    
    
    func readLastDirectory() -> String {
        return UserDefaults.standard.string(forKey: "CreatePhaseLastSaveDirectory") ?? ""
    }
}

struct CreatePhaseSaveDirectoryView: View {
    @EnvironmentObject var formData: VMCreateViewStateObject
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
                                    
                                    saveDirectory(path: path.path(percentEncoded: false))
                                    
                                    let bundleName = "\(configData.name).ezvm"
                                    let vmDir = path.appending(path: bundleName)
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
    
    
    func saveDirectory(path: String) {
        UserDefaults.standard.set(path, forKey: "CreatePhaseLastSaveDirectory")
    }
}

struct CreatePhaseSaveDirectoryView_Previews: PreviewProvider {
    static var previews: some View {
        let formData = VMCreateViewStateObject()
        CreatePhaseSaveDirectoryView()
            .environmentObject(formData)
    }
}


#endif
