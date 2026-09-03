import Foundation

public protocol VMOmarchyFactoryTransport {
    func fetchData(from url: URL) async throws -> Data
    func downloadFile(
        from url: URL,
        to destination: URL,
        resumeDataURL: URL,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws
}

public final class VMOmarchyURLSessionTransport: NSObject, VMOmarchyFactoryTransport, URLSessionDownloadDelegate {
    private struct ActiveDownload {
        let destination: URL
        let resumeDataURL: URL
        let progress: (Int64, Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var activeDownloads: [Int: ActiveDownload] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    public override init() {}

    public func fetchData(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.validateHTTPResponse(response)
        return data
    }

    public func downloadFile(
        from url: URL,
        to destination: URL,
        resumeDataURL: URL,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: destination)
        let resumeData = try? Data(contentsOf: resumeDataURL)
        try await withCheckedThrowingContinuation { continuation in
            let task = resumeData.map(session.downloadTask(withResumeData:))
                ?? session.downloadTask(with: url)
            lock.withLock {
                activeDownloads[task.taskIdentifier] = ActiveDownload(
                    destination: destination,
                    resumeDataURL: resumeDataURL,
                    progress: progress,
                    continuation: continuation
                )
            }
            task.resume()
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.withLock {
            activeDownloads[downloadTask.taskIdentifier]?.progress(
                totalBytesWritten,
                totalBytesExpectedToWrite
            )
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let active = lock.withLock({ activeDownloads[downloadTask.taskIdentifier] }) else { return }
        do {
            try Self.validateHTTPResponse(downloadTask.response)
            try FileManager.default.createDirectory(
                at: active.destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: location, to: active.destination)
        } catch {
            downloadTask.cancel()
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let active = lock.withLock({ activeDownloads.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error {
            let cocoa = error as NSError
            if let resumeData = cocoa.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? resumeData.write(to: active.resumeDataURL, options: .atomic)
            }
            active.continuation.resume(throwing: error)
        } else if FileManager.default.fileExists(atPath: active.destination.path) {
            try? FileManager.default.removeItem(at: active.resumeDataURL)
            active.continuation.resume()
        } else {
            active.continuation.resume(throwing: VMOmarchyFactoryInstallError.downloadDidNotPublish)
        }
    }

    private static func validateHTTPResponse(_ response: URLResponse?) throws {
        guard let response = response as? HTTPURLResponse,
              (200 ... 299).contains(response.statusCode) else {
            throw VMOmarchyFactoryInstallError.invalidHTTPResponse
        }
    }
}

public enum VMOmarchyFactoryInstallError: Error, Equatable, LocalizedError {
    case invalidHTTPResponse
    case downloadDidNotPublish
    case manifestTooLarge
    case invalidManifestEncoding

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            "The Omarchy release server returned an invalid response."
        case .downloadDidNotPublish:
            "The Omarchy factory download completed without a usable file."
        case .manifestTooLarge:
            "The Omarchy factory manifest exceeds the allowed size."
        case .invalidManifestEncoding:
            "The Omarchy factory manifest is not valid signed-channel metadata."
        }
    }
}

public struct VMOmarchyFactoryInstallResult: Equatable {
    public let diskURL: URL
    public let manifest: VMOmarchyFactoryManifest

    public init(diskURL: URL, manifest: VMOmarchyFactoryManifest) {
        self.diskURL = diskURL
        self.manifest = manifest
    }
}

public enum VMOmarchyFactoryChannelState: Equatable, Sendable {
    case untracked(availableVersion: String)
    case current(version: String)
    case different(installedVersion: String, availableVersion: String)

    public static func assess(
        installedVersion: String?,
        manifest: VMOmarchyFactoryManifest
    ) -> Self {
        let available = manifest.payload.imageVersion
        guard let installedVersion, !installedVersion.isEmpty else {
            return .untracked(availableVersion: available)
        }
        if installedVersion == available {
            return .current(version: installedVersion)
        }
        return .different(installedVersion: installedVersion, availableVersion: available)
    }
}

public struct VMOmarchyFactoryInstaller {
    public static let maximumManifestBytes = 256 * 1_024
    public let profile: VMOmarchyProfile
    public let cacheDirectory: URL
    public let publicKey: Data
    public let transport: any VMOmarchyFactoryTransport

    public init(
        profile: VMOmarchyProfile,
        cacheDirectory: URL,
        publicKey: Data,
        transport: any VMOmarchyFactoryTransport
    ) {
        self.profile = profile
        self.cacheDirectory = cacheDirectory
        self.publicKey = publicKey
        self.transport = transport
    }

    public func install(
        progress: @escaping (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> VMOmarchyFactoryInstallResult {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let manifest = try await fetchVerifiedManifest()

        let published = cacheDirectory.appending(path: "Factory-\(manifest.payload.imageVersion).asif")
        guard !FileManager.default.fileExists(atPath: published.path) else {
            try VMOmarchyFactoryValidator.validateImage(at: published, manifest: manifest)
            return VMOmarchyFactoryInstallResult(diskURL: published, manifest: manifest)
        }
        let staging = cacheDirectory.appending(path: ".Factory-\(UUID().uuidString).download")
        let resumeData = cacheDirectory.appending(path: "Factory.resume")
        do {
            try await transport.downloadFile(
                from: manifest.payload.imageURL,
                to: staging,
                resumeDataURL: resumeData,
                progress: progress
            )
            try VMOmarchyFactoryValidator.validateImage(at: staging, manifest: manifest)
            try FileManager.default.moveItem(at: staging, to: published)
            return VMOmarchyFactoryInstallResult(diskURL: published, manifest: manifest)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Fetches and authenticates channel metadata without downloading or
    /// changing a factory image or the user's workspace.
    public func fetchVerifiedManifest() async throws -> VMOmarchyFactoryManifest {
        let manifestData = try await transport.fetchData(from: profile.factoryImage.manifestURL)
        guard manifestData.count <= Self.maximumManifestBytes else {
            throw VMOmarchyFactoryInstallError.manifestTooLarge
        }
        let manifest: VMOmarchyFactoryManifest
        do {
            manifest = try JSONDecoder().decode(VMOmarchyFactoryManifest.self, from: manifestData)
        } catch {
            throw VMOmarchyFactoryInstallError.invalidManifestEncoding
        }
        try VMOmarchyFactoryValidator.validateManifest(manifest, profile: profile, publicKey: publicKey)
        return manifest
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
