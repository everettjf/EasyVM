//
//  VMModelFieldDirectorySharingDevice.swift
//  EZVM
//
//  Created by everettjf on 2022/10/5.
//

import Foundation
import Virtualization

#if arch(arm64)
struct VMModelFieldDirectorySharingDevice : Decodable, Encodable, CustomStringConvertible {
    struct SharingItem:  Decodable, Encodable, CustomStringConvertible {
        let name: String
        let path: URL
        let readOnly: Bool
        
        var description: String {
            "\(name)(\(readOnly ? "ReadOnly" : "ReadWrite")) \(path.path(percentEncoded: false))"
        }
    }
    
    let tag: String
    let items: [SharingItem]
    
    static let autoMoundTag = VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
    static let runtimeLinuxTag = "ezvm_shared"
    
    var description: String {
        "Tag: \(tag) Directories: \(items.map({$0.description}).joined(separator: " , "))"
    }
    
    func createConfiguration() -> VZVirtioFileSystemDeviceConfiguration? {
        if items.isEmpty {
            return nil
        }
        
        if items.count == 1 {
            let singleItem = items[0]
            let sharedDirectory = VZSharedDirectory(url: singleItem.path, readOnly: singleItem.readOnly)
            let singleDirectoryShare = VZSingleDirectoryShare(directory: sharedDirectory)
            
            // Create the VZVirtioFileSystemDeviceConfiguration and assign it a unique tag.
            let sharingConfiguration = VZVirtioFileSystemDeviceConfiguration(tag: tag)
            sharingConfiguration.share = singleDirectoryShare
            return sharingConfiguration
        }
        
        var directoriesToShare: [String: VZSharedDirectory] = [:]
        for item in items {
            directoriesToShare[item.name] = VZSharedDirectory(url: item.path, readOnly: item.readOnly)
        }

        let multipleDirectoryShare = VZMultipleDirectoryShare(directories: directoriesToShare)
        
        // Create the VZVirtioFileSystemDeviceConfiguration and assign it a unique tag.
        let sharingConfiguration = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        sharingConfiguration.share = multipleDirectoryShare
        
        return sharingConfiguration
    }

    static func createRuntimeConfiguration(
        _ devices: [VMModelFieldDirectorySharingDevice],
        osType: VMOSType
    ) -> VZVirtioFileSystemDeviceConfiguration {
        let tag = osType == .macOS ? autoMoundTag : runtimeLinuxTag
        let configuration = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        configuration.share = runtimeShare(devices)
        return configuration
    }

    static func runtimeShare(
        _ devices: [VMModelFieldDirectorySharingDevice]
    ) -> VZDirectoryShare? {
        let entries = VMSharedFolderRuntimePlan.uniquelyNamed(
            devices.flatMap(\.items).map {
                VMSharedFolderRuntimeEntry(name: $0.name, path: $0.path, readOnly: $0.readOnly)
            }
        )
        guard !entries.isEmpty else { return nil }
        if entries.count == 1, let item = entries.first {
            return VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: item.path, readOnly: item.readOnly)
            )
        }

        var names: [String: VZSharedDirectory] = [:]
        for item in entries {
            names[item.name] = VZSharedDirectory(url: item.path, readOnly: item.readOnly)
        }
        return VZMultipleDirectoryShare(directories: names)
    }
}


#endif
