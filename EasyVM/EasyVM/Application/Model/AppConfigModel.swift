//
//  AppConfig.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/18.
//

import Foundation


#if arch(arm64)
struct AppConfigModel: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    var rootPaths: [String] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case rootPaths
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        rootPaths = try container.decodeIfPresent([String].self, forKey: .rootPaths) ?? []
    }
}

@MainActor
class AppConfigManager {
    static let newVMChangedNotification = Notification.Name("NewVMChanged")

    var appConfig = AppConfigModel()
    
    init() {

    }

    func getRootPath() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "EasyVM", directoryHint: .isDirectory)
    }

    private func getLegacyConfigPath() -> URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "EasyVM", directoryHint: .isDirectory)
            .appending(path: "config.json")
    }

    func getConfigPath() -> URL {
        let rootDir = getRootPath()
        if !FileManager.default.fileExists(atPath: rootDir.path(percentEncoded: false)) {
            do {
                try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
            } catch {
                assertionFailure("Unable to create EasyVM application support directory: \(error)")
            }
        }
        
        let configPath = rootDir.appending(path: "config.json")
        let legacyConfigPath = getLegacyConfigPath()
        if !FileManager.default.fileExists(atPath: configPath.path(percentEncoded: false)),
           FileManager.default.fileExists(atPath: legacyConfigPath.path(percentEncoded: false)) {
            do {
                try FileManager.default.copyItem(at: legacyConfigPath, to: configPath)
            } catch {
                EasyVMLog.error("Legacy app config migration failed: \(error.localizedDescription)", logger: EasyVMLog.storage)
            }
        }

        return configPath
    }

    func loadConfig() {
        do {
            self.appConfig.rootPaths.removeAll()
            
            let path = getConfigPath()
            guard FileManager.default.fileExists(atPath: path.path(percentEncoded: false)) else {
                return
            }

            let data = try Data(contentsOf: path, options: .mappedIfSafe)
            self.appConfig = try JSONDecoder().decode(AppConfigModel.self, from: data)
            self.appConfig.schemaVersion = AppConfigModel.currentSchemaVersion
            self.appConfig.rootPaths = Array(NSOrderedSet(array: self.appConfig.rootPaths)) as? [String] ?? self.appConfig.rootPaths
        } catch {
            EasyVMLog.error("App config load failed: \(error.localizedDescription)", logger: EasyVMLog.storage)
        }
    }
    
    func saveConfig() {
        do {
            let path = getConfigPath()
            
            self.appConfig.schemaVersion = AppConfigModel.currentSchemaVersion
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self.appConfig)
            try data.write(to: path, options: .atomic)
        } catch {
            EasyVMLog.error("App config write failed: \(error.localizedDescription)", logger: EasyVMLog.storage)
        }
    }
    
    func addVMPath(url: URL) {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard !self.appConfig.rootPaths.contains(path) else { return }
        self.appConfig.rootPaths.append(path)
        saveConfig()
    }
    
    func removeVMPath(url: URL) {
        if let firstIndex = self.appConfig.rootPaths.firstIndex(where: { item in
            return item == url.path(percentEncoded: false)
        }) {
            self.appConfig.rootPaths.remove(at: firstIndex)
            saveConfig()
        }
    }
    
    public func addVMPathWithSelect() {
        MacKitUtil.selectDirectory(title: "Select *.ezvm directory") { @MainActor path in
            guard let path = path else {
                return
            }
            
            self.addVMPath(url: path)
            
            NotificationCenter.default.post(name: Self.newVMChangedNotification, object: nil)
        }
    }
    
    func addVMPathWithRefresh(url: URL) {
        addVMPath(url: url)
        
        NotificationCenter.default.post(name: Self.newVMChangedNotification, object: nil)
    }
    
    
    public func removeVMPathWithReload(url: URL) {
        removeVMPath(url: url)
        NotificationCenter.default.post(name: Self.newVMChangedNotification, object: nil)
    }
}

@MainActor let sharedAppConfigManager = AppConfigManager()



#endif
