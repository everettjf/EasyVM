//
//  CreatePhaseNameLocationView.swift
//  EasyVM
//
//  Created by everettjf on 2026/8/18.
//

import SwiftUI

#if arch(arm64)

class CreatePhaseNameLocationViewHandler: VMCreateStepperGuidePhaseHandler {

    static let lastDirectoryKey = "CreatePhaseLastSaveDirectory"

    // ~/Easy Virtual Machines is used when the user never picked a custom location,
    // so choosing a directory is optional in the create guide.
    static func defaultStorageDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Easy Virtual Machines")
    }

    static func readLastDirectory() -> String {
        return UserDefaults.standard.string(forKey: lastDirectoryKey) ?? ""
    }

    static func saveLastDirectory(path: String) {
        UserDefaults.standard.set(path, forKey: lastDirectoryKey)
    }

    static func bundlePath(baseDirectory: String, name: String) -> String {
        let baseURL = URL(filePath: baseDirectory)
        return baseURL.appending(path: "\(name).ezvm").path(percentEncoded: false)
    }

    private static func bundleOccupied(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else {
            return false
        }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return items.count >= 2
    }

    // "Easy Virtual Machine (macOS)" -> "Easy Virtual Machine (macOS) 2" ... until free
    static func uniqueName(baseDirectory: String, name: String) -> String {
        if !bundleOccupied(path: bundlePath(baseDirectory: baseDirectory, name: name)) {
            return name
        }
        for index in 2...100 {
            let candidate = "\(name) \(index)"
            if !bundleOccupied(path: bundlePath(baseDirectory: baseDirectory, name: candidate)) {
                return candidate
            }
        }
        return name
    }

    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        let name = context.configData.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return .failure("Name is empty")
        }
        context.configData.name = name

        if context.formData.baseDirectory.isEmpty {
            return .failure("Directory can not be empty")
        }

        let rootPath = Self.bundlePath(baseDirectory: context.formData.baseDirectory, name: name)
        context.formData.rootPath = rootPath

        if FileManager.default.fileExists(atPath: rootPath) {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: rootPath)) ?? []
            if (items.count >= 2) {
                return .failure("A machine already exists at \(rootPath). Please use another name or location.")
            }
        }

        // make sure the base directory exists (e.g. the default ~/Easy Virtual Machines)
        let baseDir = URL(filePath: context.formData.baseDirectory)
        if !FileManager.default.fileExists(atPath: baseDir.path(percentEncoded: false)) {
            do {
                try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            } catch {
                return .failure("Unable to create directory \(baseDir.path(percentEncoded: false)) : \(error.localizedDescription)")
            }
        }

        return .success
    }

    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        DispatchQueue.main.async {
            if context.formData.baseDirectory.isEmpty {
                let lastSaveDirectory = Self.readLastDirectory()
                if !lastSaveDirectory.isEmpty {
                    context.formData.baseDirectory = lastSaveDirectory
                } else {
                    context.formData.baseDirectory = Self.defaultStorageDirectory().path(percentEncoded: false)
                }

                // only auto-rename the prefilled default, never a name the user already edited
                context.configData.name = Self.uniqueName(baseDirectory: context.formData.baseDirectory, name: context.configData.name)
            }

            context.formData.rootPath = Self.bundlePath(baseDirectory: context.formData.baseDirectory, name: context.configData.name)
        }
        return .success
    }
}


struct CreatePhaseNameLocationView: View {
    @EnvironmentObject var formData: VMCreateViewStateObject
    @EnvironmentObject var configData: VMConfigurationViewStateObject

    var body: some View {

        VStack {
            Text("Name the virtual machine :")
                .font(.title3)
                .padding(.all)

            Form {
                Section("Basic") {
                    TextField("Name", text: $configData.name).lineLimit(1)

                    TextField("Description", text: $configData.remark).lineLimit(3, reservesSpace: true)
                }

                Section("Location") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Machine files will be saved to :")
                            Spacer()
                            Text(formData.rootPath)
                                .lineLimit(4)
                        }

                        HStack {
                            Text("By default machines are stored in ~/Easy Virtual Machines. Pick another directory only if you want a different location.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                MacKitUtil.selectDirectory(title: "Select a directory") { path in
                                    print("directory = \(String(describing: path))")
                                    guard let path = path else {
                                        return
                                    }

                                    let baseDirectory = path.path(percentEncoded: false)
                                    CreatePhaseNameLocationViewHandler.saveLastDirectory(path: baseDirectory)
                                    formData.baseDirectory = baseDirectory
                                    refreshRootPath()
                                }
                            } label: {
                                Image(systemName: "folder.badge.plus")
                                Text("Change")
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: configData.name) { _ in
            refreshRootPath()
        }
    }

    func refreshRootPath() {
        if formData.baseDirectory.isEmpty {
            return
        }
        formData.rootPath = CreatePhaseNameLocationViewHandler.bundlePath(baseDirectory: formData.baseDirectory, name: configData.name)
    }
}

struct CreatePhaseNameLocationView_Previews: PreviewProvider {
    static let formData = VMCreateViewStateObject()
    static let configData = VMConfigurationViewStateObject()

    static var previews: some View {
        CreatePhaseNameLocationView()
            .frame(width: 600, height: 500)
            .environmentObject(formData)
            .environmentObject(configData)
    }
}

#endif
