/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Constants that point to the various file URLs that are used by this sample code.
*/

import Foundation

let vmBundlePath = NSHomeDirectory() + "/VM.bundle/"

let diskImagePath = vmBundlePath + "Disk.img"

let auxiliaryStorageURL = URL(fileURLWithPath: vmBundlePath + "AuxiliaryStorage")

let machineIdentifierURL = URL(fileURLWithPath: vmBundlePath + "MachineIdentifier")

let hardwareModelURL = URL(fileURLWithPath: vmBundlePath + "HardwareModel")

let restoreImageURL = URL(fileURLWithPath: vmBundlePath + "RestoreImage.ipsw")
