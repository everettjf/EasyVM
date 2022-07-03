//
//  MacOSInstall.swift
//  EasyVM
//
//  Created by gipyzarc on 2022/7/3.
//

import Foundation

#if arch(arm64)
class MacOSInstall {
    
    let installer = MacOSVirtualMachineInstaller()

    var restoreImage: MacOSRestoreImage?
    
    
    func installWithIPSW(ipswPath: URL) {
        guard ipswPath.isFileURL else {
            fatalError("The provided IPSW path is not a valid file URL.")
        }

        installer.setUpVirtualMachineArtifacts()
        installer.installMacOS(ipswURL: ipswPath)
    }
    
    
    func installWithOnline() {

        installer.setUpVirtualMachineArtifacts()

        self.restoreImage = MacOSRestoreImage()
        restoreImage?.download {
            // Install from the restore image that has been downloaded.
            self.installer.installMacOS(ipswURL: restoreImageURL)
        }
        
        
    }
}

#else

//NSLog("This tool can only be run on Apple Silicon Macs.")

#endif

let sharedMacOSInstaller = MacOSInstall()
