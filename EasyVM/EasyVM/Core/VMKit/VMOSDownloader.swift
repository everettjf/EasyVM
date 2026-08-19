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
        switch osType {
        case .macOS:
            return VMOSDownloaderForMacOS()
        case .linux:
            return VMOSDownloaderForLinux()
        }
    }
}


// Plain HTTP file download with progress, shared by the macOS and Linux downloaders.
class VMOSHTTPFileDownloader {
    private var downloadObserver: NSKeyValueObservation?
    private var downloadTask: URLSessionDownloadTask?

    func download(imageURL: URL, toLocalPath: URL, completionHandler: @escaping (VMOSResultVoid) -> Void, downloadProgressHandler: @escaping (Double) -> Void) {
        downloadTask = URLSession.shared.downloadTask(with: imageURL) { localURL, response, error in
            if let error = error {
                completionHandler(.failure("Download failed. \(error.localizedDescription)."))
                return
            }
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
                completionHandler(.failure("Download failed : server returned \(httpResponse.statusCode) for \(imageURL.absoluteString)"))
                return
            }
            guard let localURL = localURL else {
                completionHandler(.failure("Download failed : local url is nil"))
                return
            }

            try? FileManager.default.removeItem(at: toLocalPath)
            guard (try? FileManager.default.moveItem(at: localURL, to: toLocalPath)) != nil else {
                completionHandler(.failure("Failed to move downloaded image to \(toLocalPath)."))
                return
            }

            completionHandler(.success)
        }

        downloadObserver = downloadTask?.progress.observe(\.fractionCompleted, options: [.initial, .new]) { (progress, change) in
            NSLog("Image download progress: \(change.newValue! * 100).")
            downloadProgressHandler(change.newValue!)
        }
        downloadTask?.resume()
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
    }
}

#endif
