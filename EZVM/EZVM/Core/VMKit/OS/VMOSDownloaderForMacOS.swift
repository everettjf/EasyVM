//
//  VMOSImageDownloadForMacOS.swift
//  EZVM
//
//  Created by everettjf on 2022/9/27.
//

import Foundation
import Virtualization


#if arch(arm64)

class VMOSDownloaderForMacOS : VMOSDownloader {
    private let fileDownloader = VMOSHTTPFileDownloader()
    private let stateLock = NSLock()
    private var latestCompletion: ((VMOSResultVoid) -> Void)?

    func isSupport() -> Bool {
        true
    }

    func downloadLatest(toLocalPath: URL, completionHandler: @escaping (VMOSResultVoid) -> Void, downloadProgressHandler: @escaping (Double) -> Void) {
        guard VMHostCapability.virtualization.isGranted else {
            completionHandler(.failure("This build is not signed with the Apple virtualization entitlement. Build EZVM with code signing enabled, or install an official signed release."))
            return
        }

        stateLock.withLock { latestCompletion = completionHandler }
        VZMacOSRestoreImage.fetchLatestSupported { [self](result: Result<VZMacOSRestoreImage, Error>) in
            guard stateLock.withLock({ latestCompletion != nil }) else { return }
            switch result {
            case let .failure(error):
                finishLatest(.failure("Apple’s restore image service is unavailable: \(error.localizedDescription) Check your internet connection and try again, or choose a specific macOS image."))

            case let .success(restoreImage):
                fileDownloader.download(imageURL: restoreImage.url, toLocalPath: toLocalPath, completionHandler: finishLatest, downloadProgressHandler: downloadProgressHandler)
            }
        }
    }

    func downloadURL(imageURL: URL, toLocalPath: URL, completionHandler: @escaping (VMOSResultVoid) -> Void, downloadProgressHandler: @escaping (Double) -> Void) {
        fileDownloader.download(imageURL: imageURL, toLocalPath: toLocalPath, completionHandler: completionHandler, downloadProgressHandler: downloadProgressHandler)
    }

    func cancelDownload() {
        fileDownloader.cancel()
        finishLatest(.failure("The download was cancelled. Retry to resume it."))
    }

    private func finishLatest(_ result: VMOSResultVoid) {
        let completion = stateLock.withLock { () -> ((VMOSResultVoid) -> Void)? in
            let completion = latestCompletion
            latestCompletion = nil
            return completion
        }
        completion?(result)
    }

}


#endif
