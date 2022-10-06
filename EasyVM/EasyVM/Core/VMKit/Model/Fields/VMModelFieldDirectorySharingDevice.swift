//
//  VMModelFieldDirectorySharingDevice.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/5.
//

import Foundation
import Virtualization

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
    
    var description: String {
        "Tag: \(tag) Directories: \(items.map({$0.description}).joined(separator: " , "))"
    }
    
    func createConfiguration() -> VZVirtioFileSystemDeviceConfiguration? {
        if items.isEmpty {
            return nil
        }
        
        if items.count == 0 {
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
}

