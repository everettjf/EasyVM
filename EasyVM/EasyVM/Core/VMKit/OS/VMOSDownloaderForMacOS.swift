//
//  VMOSImageDownloadForMacOS.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/27.
//

import Foundation
import Security
import Virtualization


#if arch(arm64)

class VMOSDownloaderForMacOS : VMOSDownloader {
    private let fileDownloader = VMOSHTTPFileDownloader()

    func isSupport() -> Bool {
        true
    }

    func downloadLatest(toLocalPath: URL, completionHandler: @escaping (VMOSResultVoid) -> Void, downloadProgressHandler: @escaping (Double) -> Void) {
        guard hasVirtualizationEntitlement else {
            completionHandler(.failure("This build is not signed with the Apple virtualization entitlement. Build EasyVM with code signing enabled, or install an official signed release."))
            return
        }

        VZMacOSRestoreImage.fetchLatestSupported { [self](result: Result<VZMacOSRestoreImage, Error>) in
            switch result {
            case let .failure(error):
                completionHandler(.failure("Apple’s restore image service is unavailable: \(error.localizedDescription) Check your internet connection and try again, or choose a specific macOS image."))

            case let .success(restoreImage):
                fileDownloader.download(imageURL: restoreImage.url, toLocalPath: toLocalPath, completionHandler: completionHandler, downloadProgressHandler: downloadProgressHandler)
            }
        }
    }

    func downloadURL(imageURL: URL, toLocalPath: URL, completionHandler: @escaping (VMOSResultVoid) -> Void, downloadProgressHandler: @escaping (Double) -> Void) {
        fileDownloader.download(imageURL: imageURL, toLocalPath: toLocalPath, completionHandler: completionHandler, downloadProgressHandler: downloadProgressHandler)
    }

    func cancelDownload() {
        fileDownloader.cancel()
    }

    private var hasVirtualizationEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.virtualization" as CFString,
            nil
        ) as? Bool == true
    }
}


#endif
