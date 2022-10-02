//
//  AppConfig.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/18.
//

import Foundation


struct AppConfigModel: Decodable, Encodable {
    var rootPaths: [String] = []
}

class AppConfigManager {

    var appConfig = AppConfigModel()
    
    init() {

    }
    
    func getConfigPath() -> URL {
        let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let url = urls.first!
        return url.appending(path: "config.json")
    }

    func loadConfig() {
        do {
            self.appConfig.rootPaths.removeAll()
            
            let path = getConfigPath()
            let data = try Data(contentsOf: path)
            self.appConfig = try JSONDecoder().decode(AppConfigModel.self, from: data)
        } catch {
            print("app config load error : \(error)")
        }
    }
    
    func saveConfig() {
        do {
            let path = getConfigPath()
            
            let data = try JSONEncoder().encode(self.appConfig)
            try data.write(to: path)
        } catch {
            print("write app config failed : \(error)")
        }
    }
    
    func addVMPath(url: URL) {
        self.appConfig.rootPaths.append(url.path(percentEncoded: false))
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
}

let sharedAppConfigManager = AppConfigManager()


