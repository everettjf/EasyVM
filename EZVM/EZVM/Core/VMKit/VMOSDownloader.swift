//
//  VMOSImageDownloader.swift
//  EZVM
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
class VMOSHTTPFileDownloader: NSObject, URLSessionDownloadDelegate {
    private let stateLock = NSLock()
    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private var targetURL: URL?
    private var completionHandler: ((VMOSResultVoid) -> Void)?
    private var progressHandler: ((Double) -> Void)?
    private var expectedTotalSize: Int64 = -1

    private var resumeDataURL: URL? {
        targetURL?.appendingPathExtension("resumeData")
    }

    func download(imageURL: URL, toLocalPath: URL, completionHandler: @escaping (VMOSResultVoid) -> Void, downloadProgressHandler: @escaping (Double) -> Void) {
        cancel(notify: false)
        stateLock.withLock {
            targetURL = toLocalPath
            self.completionHandler = completionHandler
            progressHandler = downloadProgressHandler
            expectedTotalSize = -1
        }

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        if let resumeDataURL,
           let resumeData = try? Data(contentsOf: resumeDataURL),
           !resumeData.isEmpty {
            downloadTask = session?.downloadTask(withResumeData: resumeData)
        } else {
            downloadTask = session?.downloadTask(with: imageURL)
        }
        downloadTask?.resume()
    }

    func cancel() {
        cancel(notify: true)
    }

    private func cancel(notify: Bool) {
        let state = stateLock.withLock { () -> (URLSessionDownloadTask?, URLSession?, URL?, ((VMOSResultVoid) -> Void)?) in
            let state = (downloadTask, session, resumeDataURL, notify ? completionHandler : nil)
            downloadTask = nil
            session = nil
            completionHandler = nil
            progressHandler = nil
            return state
        }
        state.0?.cancel { [resumeDataURL = state.2] resumeData in
            guard let resumeData, let resumeDataURL else { return }
            try? resumeData.write(to: resumeDataURL, options: .atomic)
        }
        state.1?.invalidateAndCancel()
        state.3?(.failure("The download was cancelled. Retry to resume it."))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard stateLock.withLock({ self.downloadTask === downloadTask }) else { return }
        guard totalBytesExpectedToWrite > 0 else { return }
        expectedTotalSize = totalBytesExpectedToWrite
        let handler = stateLock.withLock { progressHandler }
        handler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let targetURL = stateLock.withLock({ self.downloadTask === downloadTask ? self.targetURL : nil }) else { return }
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            finish(.failure("Download failed: server returned HTTP \(response.statusCode)."))
            return
        }
        do {
            let values = try location.resourceValues(forKeys: [.fileSizeKey])
            let actualSize = Int64(values.fileSize ?? 0)
            let expectedSize = expectedTotalSize
            guard actualSize > 0 else { throw VMDownloadValidationError.emptyFile }
            if expectedSize > 0, actualSize != expectedSize {
                throw VMDownloadValidationError.sizeMismatch(expected: expectedSize, actual: actualSize)
            }
            try? FileManager.default.removeItem(at: targetURL)
            try FileManager.default.moveItem(at: location, to: targetURL)
            if let resumeDataURL { try? FileManager.default.removeItem(at: resumeDataURL) }
            finish(.success)
        } catch {
            finish(.failure("Downloaded image validation failed: \(error.localizedDescription)"))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard stateLock.withLock({ self.downloadTask === task }) else { return }
        defer {
            stateLock.withLock {
                guard self.downloadTask === task else { return }
                self.downloadTask = nil
                self.session = nil
                self.targetURL = nil
            }
        }
        guard let error else { return }
        let nsError = error as NSError
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           let resumeDataURL {
            try? resumeData.write(to: resumeDataURL, options: .atomic)
        }
        if nsError.code != NSURLErrorCancelled {
            finish(.failure("Download failed. \(error.localizedDescription). It can be resumed by retrying."))
        }
    }

    private func finish(_ result: VMOSResultVoid) {
        let completion = stateLock.withLock { () -> ((VMOSResultVoid) -> Void)? in
            let completion = completionHandler
            completionHandler = nil
            progressHandler = nil
            return completion
        }
        completion?(result)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

#endif
