//
//  VMOSImageDownloader.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/27.
//

import Foundation

#if arch(arm64)
protocol VMOSDownloader {
    func isSupport() -> Bool
    func downloadLatest(toLocalPath: URL, completionHandler: @escaping (VMOSResultVoid) -> Void, downloadProgressHandler: @escaping (Double) -> Void) -> Void
    func downloadURL(imageURL: URL, toLocalPath: URL, completionHandler: @escaping (VMOSResultVoid) -> Void, downloadProgressHandler: @escaping (Double) -> Void) -> Void
    func cancelDownload()
}


class VMOSDownloaderFactory {
    static func getDownloader(_ osType: VMOSType) -> VMOSDownloader {
        return VMOSDownloaderForMacOS()
    }
}


#endif
