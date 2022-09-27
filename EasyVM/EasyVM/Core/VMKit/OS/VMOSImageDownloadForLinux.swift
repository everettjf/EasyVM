//
//  VMOSImageDownloadForLinux.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/27.
//

import Foundation


class VMOSImageDownloadForLinux : VMOSImageDownloader {
    func isSupport() -> Bool {
        false
    }
    
    func downloadLatest(toLocalPath: URL, completionHandler: @escaping (VMOSResult) -> Void, downloadProgressHandler: @escaping (Double) -> Void) {
        
    }
    func downloadURL(imageURL: URL, toLocalPath: URL, completionHandler: @escaping (VMOSResult) -> Void, downloadProgressHandler: @escaping (Double) -> Void) {
        
    }
    
    func cancelDownload() {
        
    }
}
