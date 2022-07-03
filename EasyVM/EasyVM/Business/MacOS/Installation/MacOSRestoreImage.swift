/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Download the latest macOS restore image from the network.
*/

import Foundation
import Virtualization

#if arch(arm64)

class MacOSRestoreImage: NSObject {
    private var downloadObserver: NSKeyValueObservation?

    // MARK: Observe the download progress

    public func download(completionHandler: @escaping () -> Void) {
        NSLog("Attempting to download latest available restore image.")
        VZMacOSRestoreImage.fetchLatestSupported { [self](result: Result<VZMacOSRestoreImage, Error>) in
            switch result {
                case let .failure(error):
                    fatalError(error.localizedDescription)

                case let .success(restoreImage):
                    downloadRestoreImage(restoreImage: restoreImage, completionHandler: completionHandler)
            }
        }
    }

    // MARK: Download the Restore Image from the network

    private func downloadRestoreImage(restoreImage: VZMacOSRestoreImage, completionHandler: @escaping () -> Void) {
        let downloadTask = URLSession.shared.downloadTask(with: restoreImage.url) { localURL, response, error in
            if let error = error {
                fatalError("Download failed. \(error.localizedDescription).")
            }

            guard (try? FileManager.default.moveItem(at: localURL!, to: MacOSPath.restoreImageURL)) != nil else {
                fatalError("Failed to move downloaded restore image to \(MacOSPath.restoreImageURL).")
            }

            completionHandler()
        }

        downloadObserver = downloadTask.progress.observe(\.fractionCompleted, options: [.initial, .new]) { (progress, change) in
            NSLog("Restore image download progress: \(change.newValue! * 100).")
        }
        downloadTask.resume()
    }
}

#endif
