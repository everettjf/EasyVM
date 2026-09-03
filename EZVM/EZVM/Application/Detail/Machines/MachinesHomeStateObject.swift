//
//  MachinesHomeStateObject.swift
//  EZVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI
import Observation

#if arch(arm64)
struct HomeItemVMModel : Identifiable {
    let rootPath: URL
    let model: VMModel?

    var id: URL { rootPath.standardizedFileURL }
}

@MainActor
@Observable
class MachinesHomeStateObject {
    var vmItems: [HomeItemVMModel] = []
    @ObservationIgnored nonisolated(unsafe) private var changeObserver: NSObjectProtocol?
    
    init() {
        reload()
        
        changeObserver = NotificationCenter.default.addObserver(forName: AppConfigManager.newVMChangedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }
    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }
    
    func reload() {
        sharedAppConfigManager.loadConfig()
        vmItems.removeAll()
        let rootPaths = sharedAppConfigManager.appConfig.rootPaths
        for rootPath in rootPaths {
            let rootURL = URL(filePath: rootPath)
            
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: rootURL.path(percentEncoded: false), isDirectory: &isDirectory) {
                // not existed
                vmItems.append(HomeItemVMModel(rootPath: rootURL, model: nil))
                continue
            }
            if !isDirectory.boolValue {
                // not directory
                vmItems.append(HomeItemVMModel(rootPath: rootURL, model: nil))
                continue
            }
            
            let loadModelResult = VMModel.loadConfigFromFile(rootPath: rootURL)
            switch loadModelResult {
            case .failure(let error):
                EZVMLog.error("Failed to load a registered VM: \(error)", logger: EZVMLog.storage)
                vmItems.append(HomeItemVMModel(rootPath: rootURL, model: nil))
                continue
            case .success(let model):
                vmItems.append(HomeItemVMModel(rootPath: rootURL, model: model))
            }
        }
    }
}

#endif
