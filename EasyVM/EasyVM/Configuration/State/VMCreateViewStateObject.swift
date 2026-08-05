//
//  CreateFormModel.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/15.
//

import SwiftUI

#if arch(arm64)
@MainActor
class VMCreateViewStateObject: ObservableObject {
    struct LogModel : Identifiable {
        let id = UUID()
        let time: String
        let log: String
        
        init(_ log: String) {
            let date = Date()
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "HH:mm:ss"
            self.time = dateFormatter.string(from: date)
            
            self.log = log
        }
    }
    
    
    // phase
    @Published var rootPath: String = ""

    // phase
    @Published var imagePath: String = ""
    
    @Published var logs: [LogModel] = []
    
    @Published var installingProgress: Double = 0.0
    
    @Published var disablePreviousButton = false
    
    
    init() {
    }
    
    func addLog(_ log: String) {
        logs.insert(LogModel(log), at: 0)
    }
    
    func changeProgress(_ percent: Double) {
        if percent > 1.0 {
            return
        }
        if percent < 0.0 {
            return
        }
        installingProgress = percent
    }
    
    func getSystemImagePathForDownload(osType: VMOSType) -> URL? {
        
        if !FileManager.default.fileExists(atPath: rootPath) {
            do {
                try FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
            } catch {
                addLog("Unable to create the VM directory: \(error.localizedDescription)")
                return nil
            }
        }

        let vmDir = URL(filePath: rootPath)

        var localPath = vmDir.appending(path: "SystemImage.ipsw")
        if osType == .linux {
            localPath = vmDir.appending(path: "SystemImage.iso")
        }
        return localPath
    }
    
}


#endif
