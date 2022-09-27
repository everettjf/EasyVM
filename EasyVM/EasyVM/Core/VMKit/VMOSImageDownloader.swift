//
//  VMOSImageDownloader.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/27.
//

import Foundation

protocol VMOSImageDownloader {
    func isSupport() -> Bool
    func downloadLatest(toLocalPath: URL, completionHandler: @escaping (VMOSResult) -> Void, downloadProgressHandler: @escaping (Double) -> Void) -> Void
    func downloadURL(imageURL: URL, toLocalPath: URL, completionHandler: @escaping (VMOSResult) -> Void, downloadProgressHandler: @escaping (Double) -> Void) -> Void
}


class VMOSImageDownloadFactory {
    static func getDownloader(_ osType: VMOSType) -> VMOSImageDownloader {
        return VMOSImageDownloadForMacOS()
    }
}

