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

    // A compact, offline catalog of filesystem-safe astronomical names. The
    // names are intentionally bundled with the app so suggestions never depend
    // on network availability or an app update service.
    static let suggestedNames = [
        "Mercury", "Venus", "Earth", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune",
        "Ceres", "Pluto", "Haumea", "Makemake", "Eris", "Luna", "Europa", "Ganymede",
        "Callisto", "Io", "Titan", "Enceladus", "Triton", "Charon",
        "Sirius", "Canopus", "Arcturus", "Vega", "Capella", "Rigel", "Procyon", "Betelgeuse",
        "Achernar", "Hadar", "Altair", "Acrux", "Aldebaran", "Antares", "Spica", "Pollux",
        "Fomalhaut", "Deneb", "Regulus", "Castor", "Bellatrix", "Elnath", "Alnilam", "Alnair",
        "Alioth", "Dubhe", "Mirfak", "Wezen", "Sargas", "Kaus", "Avior", "Alkaid",
        "Menkalinan", "Atria", "Alhena", "Peacock", "Mirzam", "Alphard", "Hamal", "Diphda",
        "Andromeda", "Milky Way", "Triangulum", "Whirlpool", "Sombrero", "Pinwheel", "Sunflower",
        "Cartwheel", "Black Eye", "Cigar", "Bode", "Sculptor", "Centaurus", "Tadpole", "Condor",
        "Comet", "Fireworks", "Malin", "Mayall", "Hoag",
        "Orion", "Carina", "Helix", "Crab", "Eagle", "Lagoon", "Trifid", "Rosette", "Veil",
        "Horsehead", "Catseye", "Ring", "Tarantula", "Bubble", "Butterfly", "Pelican",
        "North America", "Omega"
    ]

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

    static func randomName(baseDirectory: String, excluding currentName: String? = nil) -> String {
        for name in suggestedNames.shuffled() where name != currentName {
            if !bundleOccupied(path: bundlePath(baseDirectory: baseDirectory, name: name)) {
                return name
            }
        }

        // This is only reached when every catalog name is already occupied.
        return uniqueName(baseDirectory: baseDirectory, name: suggestedNames.randomElement() ?? "Nova")
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

            }

            if !context.formData.hasGeneratedNameSuggestion {
                context.configData.name = Self.randomName(baseDirectory: context.formData.baseDirectory)
                context.formData.hasGeneratedNameSuggestion = true
            }

            context.formData.rootPath = Self.bundlePath(baseDirectory: context.formData.baseDirectory, name: context.configData.name)
        }
        return .success
    }
}


struct CreatePhaseNameLocationView: View {
    @Environment(VMCreateViewStateObject.self) var formData
    @Environment(VMConfigurationViewStateObject.self) var configData

    var body: some View {
        @Bindable var configData = configData
        VStack {
            Text("Name the virtual machine :")
                .font(.title3)
                .padding(.all)

            Form {
                Section("Basic") {
                    HStack {
                        TextField("Name", text: $configData.name).lineLimit(1)
                        Button {
                            let baseDirectory = formData.baseDirectory.isEmpty
                                ? CreatePhaseNameLocationViewHandler.defaultStorageDirectory().path(percentEncoded: false)
                                : formData.baseDirectory
                            configData.name = CreatePhaseNameLocationViewHandler.randomName(
                                baseDirectory: baseDirectory,
                                excluding: configData.name
                            )
                        } label: {
                            Image(systemName: "dice")
                        }
                        .buttonStyle(.borderless)
                        .help("Suggest another astronomical name")
                        .accessibilityLabel("Suggest another name")
                        .accessibilityIdentifier("randomize-vm-name")
                    }

                    TextField("Description", text: $configData.remark).lineLimit(3, reservesSpace: true)
                }

                Section("Location") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Machine files will be saved to :")
                            Spacer()
                            Text(displayRootPath)
                                .lineLimit(4)
                        }

                        HStack {
                            Text("By default machines are stored in ~/Easy Virtual Machines. Pick another directory only if you want a different location.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                MacKitUtil.selectDirectory(title: "Select a directory") { path in
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
        .onChange(of: configData.name) {
            refreshRootPath()
        }
    }

    func refreshRootPath() {
        if formData.baseDirectory.isEmpty {
            return
        }
        formData.rootPath = CreatePhaseNameLocationViewHandler.bundlePath(baseDirectory: formData.baseDirectory, name: configData.name)
    }

    private var displayRootPath: String {
        NSString(string: formData.rootPath).abbreviatingWithTildeInPath
    }
}

struct CreatePhaseNameLocationView_Previews: PreviewProvider {
    static let formData = VMCreateViewStateObject()
    static let configData = VMConfigurationViewStateObject()

    static var previews: some View {
        CreatePhaseNameLocationView()
            .frame(width: 600, height: 500)
            .environment(formData)
            .environment(configData)
    }
}

#endif
