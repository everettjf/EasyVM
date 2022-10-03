//
//  MachinesHomeStateObject.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI

struct HomeItemVMModel : Identifiable {
    let id = UUID()
    let rootPath: URL
    let model: VMModel?
}

class MachinesHomeStateObject: ObservableObject {
    @Published var vmItems: [HomeItemVMModel] = []
    
    init() {
        reload()
        
        NotificationCenter.default.addObserver(forName: AppConfigManager.NewVMChangedNotification, object: nil, queue: OperationQueue.main) { [weak self] notification in
            DispatchQueue.main.async {
                self?.reload()
            }
        }
    }
    deinit {
        NotificationCenter.default.removeObserver(self)
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
                print("load vm error : \(error)")
                vmItems.append(HomeItemVMModel(rootPath: rootURL, model: nil))
                continue
            case .success(let model):
                vmItems.append(HomeItemVMModel(rootPath: rootURL, model: model))
            }
        }
    }
}
