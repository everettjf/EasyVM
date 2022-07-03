/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Constants that point to the various file URLs that are used by this sample code.
*/

import Foundation

class MacOSPath {
    

    static let vmBundlePath = NSHomeDirectory() + "/VM.bundle/"

    static let diskImagePath = vmBundlePath + "Disk.img"

    static let auxiliaryStorageURL = URL(fileURLWithPath: vmBundlePath + "AuxiliaryStorage")

    static let machineIdentifierURL = URL(fileURLWithPath: vmBundlePath + "MachineIdentifier")

    static let hardwareModelURL = URL(fileURLWithPath: vmBundlePath + "HardwareModel")

    static let restoreImageURL = URL(fileURLWithPath: vmBundlePath + "RestoreImage.ipsw")
    
}

