//
//  CreatePhaseChooseStorageDirectoryView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

#if arch(arm64)
class CreatePhaseSaveDirectoryViewHandler: VMCreateStepperGuidePhaseHandler {

    // ~/EasyVM is used when the user never picked a custom location,
    // so choosing a directory is optional in the create guide.
    static func defaultStorageDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "EasyVM")
    }

    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        if context.formData.rootPath.isEmpty {
            return .failure("Directory can not be empty")
        }

        if FileManager.default.fileExists(atPath: context.formData.rootPath) {

            let items = (try? FileManager.default.contentsOfDirectory(atPath: context.formData.rootPath)) ?? []
            if (items.count >= 2) {
                return .failure("Directory already existed : \(context.formData.rootPath)")
            }
        }

        // make sure the parent directory exists (e.g. the default ~/EasyVM)
        let parentDir = URL(filePath: context.formData.rootPath).deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path(percentEncoded: false)) {
            do {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            } catch {
                return .failure("Unable to create directory \(parentDir.path(percentEncoded: false)) : \(error.localizedDescription)")
            }
        }

        return .success
    }
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        DispatchQueue.main.async {
            var baseURL = Self.defaultStorageDirectory()

            let lastSaveDirectory = self.readLastDirectory()
            if !lastSaveDirectory.isEmpty {
                baseURL = URL(filePath: lastSaveDirectory)
            }

            let bundleName = "\(context.configData.name).ezvm"
            let vmDir = baseURL.appending(path: bundleName)
            context.formData.rootPath = vmDir.path(percentEncoded: false)
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
                            Text("Machine files will be saved to :")
                            Spacer()
                            Text(formData.rootPath)
                                .lineLimit(4)
                        }

                        HStack {
                            Text("By default machines are stored in ~/EasyVM. Pick another directory only if you want a different location.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
