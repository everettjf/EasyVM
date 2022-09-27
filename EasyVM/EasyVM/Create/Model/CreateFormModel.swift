//
//  CreateFormModel.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/15.
//

import SwiftUI

class CreateFormModel: ObservableObject {
    // --- Form ---
    // phase
    @Published var osType: VMOSType = .macOS
    
    // phase
    @Published var name: String = "My New Virtual Machine"
    @Published var remark: String = ""
    
    // phase
    @Published var saveDirectory: String = "file:///Users/everettjf/Downloads/"

    // phase
    @Published var imagePath: String = "file:///Users/everettjf/Downloads/UniversalMac_13.0_22A5295h_Restore.ipsw"
    
    // phase - confirguration
    
    
    func getSystemImagePath() -> URL? {
        guard let path = URL(string: saveDirectory) else {
            return nil
        }
        
        let vmDir = path.appending(path: name)
        if !FileManager.default.fileExists(atPath: vmDir.path) {
            try? FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)
        }
        
        var localPath = vmDir.appending(path: "SystemImage.ipsw")
        if osType == .linux {
            localPath = vmDir.appending(path: "SystemImage.iso")
        }
        return localPath
    }
}
