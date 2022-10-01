//
//  VMOSImageDownloadForMacOS.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/27.
//

import Foundation
import Virtualization

class VMOSImageDownloadForMacOS : VMOSImageDownloader {
    private var downloadObserver: NSKeyValueObservation?
    private var downloadTask: URLSessionDownloadTask?
    
    func isSupport() -> Bool {
        true
    }
    
    func downloadLatest(toLocalPath: URL, completionHandler: @escaping (VMOSResultVoid) -> Void, downloadProgressHandler: @escaping (Double) -> Void) {
        
        VZMacOSRestoreImage.fetchLatestSupported { [self](result: Result<VZMacOSRestoreImage, Error>) in
            switch result {
            case let .failure(error):
                completionHandler(.failure("Failed to fetch latest supported image : \(error.localizedDescription)"))

            case let .success(restoreImage):
                downloadRestoreImage(toLocalPath: toLocalPath, imageURL: restoreImage.url, completionHandler: completionHandler, downloadProgressHandler: downloadProgressHandler)
            }
        }
    }
    
    func downloadURL(imageURL: URL, toLocalPath: URL, completionHandler: @escaping (VMOSResultVoid) -> Void, downloadProgressHandler: @escaping (Double) -> Void) {
        downloadRestoreImage(toLocalPath: toLocalPath, imageURL: imageURL, completionHandler: completionHandler, downloadProgressHandler: downloadProgressHandler)
    }
    
    private func downloadRestoreImage(toLocalPath: URL, imageURL: URL, completionHandler: @escaping (VMOSResultVoid) -> Void, downloadProgressHandler: @escaping (Double) -> Void) {
        downloadTask = URLSession.shared.downloadTask(with: imageURL) { localURL, response, error in
            if let error = error {
                completionHandler(.failure("Download failed. \(error.localizedDescription)."))
                return
            }
            guard let localURL = localURL else {
                completionHandler(.failure("Download failed : local url is nil"))
                return
            }

            guard (try? FileManager.default.moveItem(at: localURL, to: toLocalPath)) != nil else {
                completionHandler(.failure("Failed to move downloaded restore image to \(toLocalPath)."))
                return
            }

            completionHandler(.success)
        }

        downloadObserver = downloadTask?.progress.observe(\.fractionCompleted, options: [.initial, .new]) { (progress, change) in
            NSLog("Restore image download progress: \(change.newValue! * 100).")
            downloadProgressHandler(change.newValue!)
        }
        downloadTask?.resume()
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }
}
