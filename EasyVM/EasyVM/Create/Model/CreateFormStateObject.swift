//
//  CreateFormModel.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/15.
//

import SwiftUI

class CreateFormStateObject: ObservableObject {
    // phase
    @Published var rootPath: String = "/Users/everettjf/Downloads/NewVirtualMachine"

    // phase
    @Published var imagePath: String = "/Users/everettjf/Downloads/UniversalMac_13.0_22A5295h_Restore.ipsw"
    
    
    init() {
    }
    
    init(saveDirectory: String, imagePath: String) {
        self.rootPath = saveDirectory
        self.imagePath = imagePath
    }
    

    func getSystemImagePath(osType: VMOSType) -> URL? {
        guard let vmDir = URL(string: rootPath) else {
            return nil
        }

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
