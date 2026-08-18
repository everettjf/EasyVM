//
//  VMOSDownloaderForLinux.swift
//  EasyVM
//
//  Created by everettjf on 2026/8/18.
//

import Foundation

#if arch(arm64)

class VMOSDownloaderForLinux : VMOSDownloader {
    private let fileDownloader = VMOSHTTPFileDownloader()

    func isSupport() -> Bool {
        true
    }

    func downloadLatest(toLocalPath: URL, completionHandler: @escaping (VMOSResultVoid) -> Void, downloadProgressHandler: @escaping (Double) -> Void) {
        // There is no single "latest" image for Linux; pick a distribution
        // from the catalog or provide a custom URL instead.
        completionHandler(.failure("Latest image is not available for Linux. Please choose a distribution or input an image URL."))
    }

    func downloadURL(imageURL: URL, toLocalPath: URL, completionHandler: @escaping (VMOSResultVoid) -> Void, downloadProgressHandler: @escaping (Double) -> Void) {
        fileDownloader.download(imageURL: imageURL, toLocalPath: toLocalPath, completionHandler: completionHandler, downloadProgressHandler: downloadProgressHandler)
    }

    func cancelDownload() {
        fileDownloader.cancel()
    }
}

#endif
