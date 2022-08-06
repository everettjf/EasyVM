//
//  LinuxPath.swift
//  EasyVM
//
//  Created by gipyzarc on 2022/7/3.
//

import Foundation

class LinuxPath {
    static let vmBundlePath = NSHomeDirectory() + "/GUI Linux VM.bundle/"
    static let mainDiskImagePath = vmBundlePath + "Disk.img"
    static let efiVariableStorePath = vmBundlePath + "NVRAM"
    static let machineIdentifierPath = vmBundlePath + "MachineIdentifier"
}
