//
//  CreatePhaseCreatingView.swift
//  EZVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI
import CryptoKit

#if arch(arm64)

class CreatePhaseCreatingViewHandler: VMCreateStepperGuidePhaseHandler {
    private var downloader: (any VMOSDownloader)?
    private var preinstalledDownloader: VMPreinstalledImageDownloadCoordinator?

    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        return .success
    }

    func cancel(context: VMCreateStepperGuidePhaseContext) {
        guard context.formData.canCancelCreation else { return }
        context.formData.canCancelCreation = false
        downloader?.cancelDownload()
        downloader = nil
        preinstalledDownloader?.cancel()
        preinstalledDownloader = nil
    }

    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        context.formData.logs = []
        context.formData.installingProgress = 0
        context.formData.creationStage = "Preparing"
        context.formData.isCreating = true
        context.formData.canCancelCreation = false

        if case .preinstalled(let item) = context.formData.systemImageSelection {
            let result = await createPreinstalledImage(item, context: context)
            context.formData.isCreating = false
            if case .success = result {
                context.formData.creationStage = "Ready"
                context.formData.changeProgress(1)
                context.formData.disablePreviousButton = true
            }
            return result
        }

        let imageResult = await resolveSystemImage(context: context)
        guard case .success(let imageURL) = imageResult else {
            context.formData.isCreating = false
            if case .failure(let error) = imageResult {
                context.formData.creationStage = "Couldn’t download the system image"
                context.formData.addLog("❌ \(error)")
                return .failure(error)
            }
            return .failure("Unable to resolve the system image")
        }
        context.formData.imagePath = imageURL.path(percentEncoded: false)

        if context.configData.osType == .linux {
            attachLinuxInstaller(imagePath: context.formData.imagePath, context: context)
        }

        // fill from form
        let rootPath = URL(filePath:context.formData.rootPath)
        let imagePath = imageURL
        EZVMLog.info("Creating VM at \(rootPath.path(percentEncoded: false)) with image \(imagePath.lastPathComponent)", logger: EZVMLog.lifecycle)

        let stateModel = VMStateModel(imagePath: imagePath)
        let configModel = context.configData.getConfigModel()
        let vmModel = VMModel(rootPath: rootPath, state: stateModel, config: configModel)

        // create vm from vmmodel
        EZVMLog.info("Starting virtual machine creation", logger: EZVMLog.lifecycle)
        context.formData.creationStage = context.configData.osType == .macOS ? "Installing macOS" : "Creating virtual machine"
        context.formData.addLog("System image is ready")
        let creator = VMOSCreateFactory.getCreator(configModel.type)
        let result = await creator.create(model: vmModel, progress: { progressInfo in
            switch progressInfo {
            case .info(let log):
                EZVMLog.info(log, logger: EZVMLog.lifecycle)
                context.formData.addLog(log)
            case .error(let log):
                EZVMLog.error(log, logger: EZVMLog.lifecycle)
                context.formData.addLog("❌ ERROR : \(log)")
            case .progress(let percent):
                context.formData.changeProgress(0.35 + (percent * 0.65))
            }
        })
        EZVMLog.info("Virtual machine creation finished", logger: EZVMLog.lifecycle)
        context.formData.isCreating = false

        switch result {
        case .failure(let error):
            context.formData.creationStage = "Creation failed"
            EZVMLog.error("Failed to create VM: \(error)", logger: EZVMLog.lifecycle)
        case .success:
            if context.formData.provisionsMacGuest {
                let credential = VMGuestProvisioningCredential(
                    fullName: context.formData.provisioningFullName,
                    username: context.formData.provisioningUsername,
                    password: context.formData.provisioningPassword,
                    logsInAutomatically: context.formData.provisioningAutomaticLogin,
                    enablesRemoteLogin: context.formData.provisioningRemoteLogin
                )
                if case let .failure(error) = VMGuestProvisioningCredentialStore.save(credential, vmRootPath: rootPath) {
                    context.formData.creationStage = "Provisioning setup failed"
                    context.formData.addLog("❌ \(error)")
                    context.formData.provisioningPassword = ""
                    context.formData.provisioningPasswordConfirmation = ""
                    return .failure(error)
                }
                context.formData.addLog("Guest credentials saved securely in Keychain for first boot")
                context.formData.provisioningPassword = ""
                context.formData.provisioningPasswordConfirmation = ""
            }
            context.formData.creationStage = "Ready"
            context.formData.changeProgress(1)
            context.formData.disablePreviousButton = true
            sharedAppConfigManager.addVMPathWithRefresh(url: rootPath)
        }

        return result
    }

    private func resolveSystemImage(context: VMCreateStepperGuidePhaseContext) async -> VMOSResult<URL, String> {
        switch context.formData.systemImageSelection {
        case .localFile(let url):
            let expectedExtension = context.configData.osType == .macOS ? "ipsw" : "iso"
            if let error = VMSystemImageFileValidator.validate(url, expectedExtension: expectedExtension) {
                return .failure("The selected image is unavailable or invalid: \(error)")
            }
            context.formData.creationStage = "Using local system image"
            context.formData.changeProgress(0.35)
            return .success(url)

        case .latestMacOS:
            guard let target = VMImageStore.preparePath(fileName: "macOS-Latest.ipsw") else {
                return .failure("Unable to prepare the system image cache")
            }
            if await cachedImageIsValid(target, expectedExtension: "ipsw", context: context) {
                context.formData.creationStage = "Using cached macOS image"
                context.formData.changeProgress(0.35)
                return .success(target)
            }
            return await downloadImage(osType: .macOS, target: target, remoteURL: nil, context: context)

        case .catalog(let item):
            let fallbackExtension = item.osType == .macOS ? "ipsw" : "iso"
            let ext = item.url.pathExtension.isEmpty ? fallbackExtension : item.url.pathExtension
            guard let target = VMImageStore.preparePath(fileName: "\(item.id).\(ext)") else {
                return .failure("Unable to prepare the system image cache")
            }
            if await cachedImageIsValid(
                target,
                expectedExtension: ext,
                expectedSize: item.fileSize,
                expectedSHA256: item.sha256,
                context: context
            ) {
                context.formData.creationStage = "Using cached system image"
                context.formData.changeProgress(0.35)
                return .success(target)
            }
            return await downloadImage(
                osType: item.osType,
                target: target,
                remoteURL: item.url,
                expectedExtension: ext,
                expectedSize: item.fileSize,
                expectedSHA256: item.sha256,
                context: context
            )

        case .preinstalled:
            return .failure("Preinstalled images use the verified import workflow.")

        case .remoteURL(let url):
            let fallbackExtension = context.configData.osType == .macOS ? "ipsw" : "iso"
            let fileName = url.lastPathComponent.isEmpty ? "CustomImage.\(fallbackExtension)" : url.lastPathComponent
            guard let target = VMImageStore.preparePath(fileName: fileName) else {
                return .failure("Unable to prepare the system image cache")
            }
            if await cachedImageIsValid(target, expectedExtension: fallbackExtension, context: context) {
                context.formData.creationStage = "Using cached system image"
                context.formData.changeProgress(0.35)
                return .success(target)
            }
            return await downloadImage(osType: context.configData.osType, target: target, remoteURL: url, context: context)
        }
    }

    private func cachedImageIsValid(
        _ target: URL,
        expectedExtension: String,
        expectedSize: Int64? = nil,
        expectedSHA256: String? = nil,
        context: VMCreateStepperGuidePhaseContext
    ) async -> Bool {
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { return false }
        guard let error = await systemImageValidationError(
            target,
            expectedExtension: expectedExtension,
            expectedSize: expectedSize,
            expectedSHA256: expectedSHA256
        ) else { return true }
        context.formData.addLog("Discarding invalid cached image: \(error)")
        do {
            try FileManager.default.removeItem(at: target)
            return false
        } catch {
            context.formData.addLog("❌ Could not remove the invalid cached image: \(error.localizedDescription)")
            return false
        }
    }

    private func createPreinstalledImage(
        _ item: VMPreinstalledImageCatalogItem,
        context: VMCreateStepperGuidePhaseContext
    ) async -> VMOSResultVoid {
        let coordinator = VMPreinstalledImageDownloadCoordinator()
        preinstalledDownloader = coordinator
        context.formData.canCancelCreation = true
        context.formData.creationStage = "Downloading \(item.name)"
        context.formData.addLog("Fetching the verified \(item.name) release manifest")

        let prepared = await coordinator.prepare(item: item) { stage, fraction in
            Task { @MainActor in
                context.formData.creationStage = stage
                context.formData.changeProgress(min(0.72, max(0, fraction) * 0.72))
            }
        }
        context.formData.canCancelCreation = false
        preinstalledDownloader = nil
        guard case .success(let assets) = prepared else {
            let message: String
            if case .failure(let error) = prepared { message = error }
            else { message = "Could not prepare the preinstalled image" }
            context.formData.creationStage = "Couldn’t prepare \(item.name)"
            context.formData.addLog("❌ \(message)")
            return .failure(message)
        }

        context.formData.creationStage = "Importing \(item.name)"
        context.formData.addLog("Verified the manifest, archive parts, compressed stream, disk, and thumbnail")
        let install = PreinstalledImageInstallConfiguration(
            manifestURL: assets.manifestURL,
            imageURL: assets.imageURL,
            destinationURL: URL(filePath: context.formData.rootPath),
            name: context.configData.name,
            thumbnailURL: assets.thumbnailURL,
            stagingToken: UUID().uuidString,
            configuration: context.configData.getConfigModel()
        )
        let result = await VMPreinstalledImageInstaller.install(install) { progress in
            switch progress {
            case .info(let message): context.formData.addLog(message)
            case .error(let message): context.formData.addLog("❌ \(message)")
            case .progress(let fraction): context.formData.changeProgress(0.72 + fraction * 0.28)
            }
        }
        if case .failure(let error) = result {
            context.formData.creationStage = "Import failed"
            context.formData.addLog("❌ \(error)")
        }
        return result
    }

    private func downloadImage(
        osType: VMOSType,
        target: URL,
        remoteURL: URL?,
        expectedExtension: String? = nil,
        expectedSize: Int64? = nil,
        expectedSHA256: String? = nil,
        context: VMCreateStepperGuidePhaseContext
    ) async -> VMOSResult<URL, String> {
        context.formData.creationStage = "Downloading system image"
        context.formData.addLog("Downloading \(context.formData.systemImageSelection.title)")
        let activeDownloader = VMOSDownloaderFactory.getDownloader(osType)
        downloader = activeDownloader
        context.formData.canCancelCreation = true

        let result: VMOSResultVoid = await withCheckedContinuation { continuation in
            let completion: (VMOSResultVoid) -> Void = { result in
                continuation.resume(returning: result)
            }
            let progress: (Double) -> Void = { fraction in
                Task { @MainActor in
                    context.formData.changeProgress(max(0, min(1, fraction)) * 0.35)
                }
            }

            if let remoteURL {
                activeDownloader.downloadURL(
                    imageURL: remoteURL,
                    toLocalPath: target,
                    completionHandler: completion,
                    downloadProgressHandler: progress
                )
            } else {
                activeDownloader.downloadLatest(
                    toLocalPath: target,
                    completionHandler: completion,
                    downloadProgressHandler: progress
                )
            }
        }
        context.formData.canCancelCreation = false
        downloader = nil

        switch result {
        case .success:
            let fallbackExtension = osType == .macOS ? "ipsw" : "iso"
            if let error = await systemImageValidationError(
                target,
                expectedExtension: expectedExtension ?? fallbackExtension,
                expectedSize: expectedSize,
                expectedSHA256: expectedSHA256
            ) {
                try? FileManager.default.removeItem(at: target)
                context.formData.addLog("❌ Downloaded image validation failed: \(error)")
                return .failure("Downloaded system image is invalid: \(error)")
            }
            context.formData.changeProgress(0.35)
            return .success(target)
        case .failure(let error):
            return .failure(error)
        }
    }

    private func systemImageValidationError(
        _ url: URL,
        expectedExtension: String,
        expectedSize: Int64?,
        expectedSHA256: String?
    ) async -> String? {
        if let error = VMSystemImageFileValidator.validate(
            url,
            expectedExtension: expectedExtension,
            expectedSize: expectedSize
        ) {
            return error
        }
        guard let expectedSHA256 else { return nil }
        return await Task.detached(priority: .utility) {
            VMSystemImageFileValidator.validateSHA256(url, expectedSHA256: expectedSHA256)
        }.value
    }

    private func attachLinuxInstaller(imagePath: String, context: VMCreateStepperGuidePhaseContext) {
        context.configData.storageDevices.removeAll {
            $0.data.type == .USB && ($0.data.imagePath.isEmpty || $0.data.imagePath == context.formData.imagePath)
        }
        context.configData.storageDevices.append(
            VMModelFieldStorageDeviceItemModel(
                data: VMModelFieldStorageDevice(type: .USB, size: 0, imagePath: imagePath)
            )
        )
    }
}

private struct VMPreparedPreinstalledImage {
    let manifestURL: URL
    let imageURL: URL
    let thumbnailURL: URL?
}

@MainActor
private final class VMPreinstalledImageDownloadCoordinator {
    private var activeDownload: VMOSHTTPFileDownloader?
    private var activeContinuation: CheckedContinuation<VMOSResultVoid, Never>?
    private var cancelled = false
    private let cancellationFlag = VMOperationCancellationFlag()

    func cancel() {
        cancelled = true
        cancellationFlag.cancel()
        activeDownload?.cancel()
        activeDownload = nil
        finishDownload(.failure("The download was cancelled."))
    }

    func prepare(
        item: VMPreinstalledImageCatalogItem,
        progress: @escaping (String, Double) -> Void
    ) async -> VMOSResult<VMPreparedPreinstalledImage, String> {
        do {
            progress("Fetching release manifest", 0.01)
            let stagingDirectory = FileManager.default.temporaryDirectory
                .appending(path: "EZVM-manifest-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stagingDirectory) }
            let stagingManifestURL = stagingDirectory.appending(path: "ezvm-release-manifest.json")
            try await download(item.manifestURL, to: stagingManifestURL) { fraction in
                progress("Fetching release manifest", 0.01 + fraction * 0.01)
            }
            let manifestData = try Data(contentsOf: stagingManifestURL)
            guard !cancelled else { throw CancellationError() }

            let decoded = try JSONDecoder().decode(PreinstalledImageManifest.self, from: manifestData)
            try Self.validateDistribution(decoded)
            guard let archive = decoded.archive, let release = decoded.release else {
                throw PreparationError.invalidManifest("The release has no archive metadata.")
            }
            let releaseBaseURL = try Self.releaseBaseURL(release)
            let cacheDirectory = try Self.cacheDirectory(itemID: item.id, tag: release.tag)
            try Self.requireAvailableSpace(at: cacheDirectory, minimumBytes: 15 * 1024 * 1024 * 1024)
            let manifestURL = cacheDirectory.appending(path: "ezvm-release-manifest.json")
            try manifestData.write(to: manifestURL, options: .atomic)
            _ = try PreinstalledImageManifest.load(from: manifestURL)

            let cachedImageURL = cacheDirectory.appending(path: "\(item.id).raw")
            let cachedThumbnailURL = decoded.thumbnail.map { cacheDirectory.appending(path: $0.name) }
            if FileManager.default.fileExists(atPath: cachedImageURL.path),
               await Self.matches(cachedImageURL, size: Int64(decoded.disk.virtualSize), sha256: decoded.disk.sha256),
               await Self.thumbnailMatches(cachedThumbnailURL, metadata: decoded.thumbnail) {
                progress("Using verified cached \(item.name) image", 1)
                return .success(VMPreparedPreinstalledImage(
                    manifestURL: manifestURL,
                    imageURL: cachedImageURL,
                    thumbnailURL: cachedThumbnailURL
                ))
            }

            var thumbnailURL: URL?
            if let thumbnail = decoded.thumbnail {
                progress("Downloading thumbnail", 0.03)
                let target = cacheDirectory.appending(path: thumbnail.name)
                try await download(releaseBaseURL.appending(path: thumbnail.name), to: target) { fraction in
                    progress("Downloading thumbnail", 0.03 + fraction * 0.01)
                }
                try await Self.verify(target, size: thumbnail.size, sha256: thumbnail.sha256)
                thumbnailURL = target
            }

            var partURLs: [URL] = []
            let totalCompressedBytes = max(archive.compressedSize, 1)
            var completedBytes: Int64 = 0
            for (index, part) in archive.parts.enumerated() {
                try Task.checkCancellation()
                guard !cancelled else { throw CancellationError() }
                let target = cacheDirectory.appending(path: part.name)
                let baseFraction = Double(completedBytes) / Double(totalCompressedBytes)
                progress("Downloading \(item.name) (\(index + 1)/\(archive.parts.count))", 0.04 + baseFraction * 0.54)
                try await download(releaseBaseURL.appending(path: part.name), to: target) { fraction in
                    let byteFraction = (Double(completedBytes) + Double(part.size) * fraction) / Double(totalCompressedBytes)
                    progress("Downloading \(item.name) (\(index + 1)/\(archive.parts.count))", 0.04 + byteFraction * 0.54)
                }
                try await Self.verify(target, size: part.size, sha256: part.sha256)
                completedBytes += part.size
                partURLs.append(target)
            }

            progress("Verifying compressed image", 0.60)
            let compressedURL = cacheDirectory.appending(path: "\(item.id).sparse.gz")
            try await Self.concatenate(
                parts: partURLs,
                to: compressedURL,
                expectedSize: archive.compressedSize,
                expectedSHA256: archive.sha256,
                cancellationFlag: cancellationFlag
            )
            for partURL in partURLs { try? FileManager.default.removeItem(at: partURL) }

            progress("Reconstructing sparse disk", 0.68)
            let imageURL = cacheDirectory.appending(path: "\(item.id).raw")
            try await Self.decodeSparseGzip(
                compressedURL,
                to: imageURL,
                expectedSize: decoded.disk.virtualSize,
                cancellationFlag: cancellationFlag
            )
            try? FileManager.default.removeItem(at: compressedURL)

            progress("Verifying reconstructed disk", 0.88)
            try await Self.verify(imageURL, size: Int64(decoded.disk.virtualSize), sha256: decoded.disk.sha256)
            progress("Preinstalled image verified", 1)
            return .success(VMPreparedPreinstalledImage(manifestURL: manifestURL, imageURL: imageURL, thumbnailURL: thumbnailURL))
        } catch is CancellationError {
            return .failure("The preinstalled image download was cancelled.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func download(_ source: URL, to target: URL, progress: @escaping (Double) -> Void) async throws {
        if FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.removeItem(at: target) }
        let downloader = VMOSHTTPFileDownloader()
        activeDownload = downloader
        let result: VMOSResultVoid = await withCheckedContinuation { continuation in
            activeContinuation = continuation
            downloader.download(
                imageURL: source,
                toLocalPath: target,
                completionHandler: { [weak self] result in
                    Task { @MainActor in self?.finishDownload(result) }
                },
                downloadProgressHandler: { fraction in
                    Task { @MainActor in progress(fraction) }
                }
            )
        }
        activeDownload = nil
        switch result {
        case .success: return
        case .failure(let message): throw PreparationError.download(message)
        }
    }

    private func finishDownload(_ result: VMOSResultVoid) {
        guard let continuation = activeContinuation else { return }
        activeContinuation = nil
        continuation.resume(returning: result)
    }

    nonisolated private static func validateDistribution(_ manifest: PreinstalledImageManifest) throws {
        guard let archive = manifest.archive,
              archive.compression == "ezvm-sparse-stream+gzip",
              archive.compressedSize > 0,
              archive.sha256.isSHA256,
              !archive.parts.isEmpty,
              archive.parts.reduce(Int64(0), { $0 + $1.size }) == archive.compressedSize,
              archive.parts.allSatisfy({ $0.size > 0 && $0.sha256.isSHA256 && $0.name.isSafeAssetName }),
              let release = manifest.release,
              release.repository == "everettjf/omarchy-aarch64-image",
              release.tag.isSafeAssetName else {
            throw PreparationError.invalidManifest("The release archive metadata is invalid or unsupported.")
        }
        if let thumbnail = manifest.thumbnail {
            guard thumbnail.mediaType == "image/png", thumbnail.size > 0,
                  thumbnail.sha256.isSHA256, thumbnail.name.isSafeAssetName else {
                throw PreparationError.invalidManifest("The release thumbnail metadata is invalid.")
            }
        }
    }

    nonisolated private static func releaseBaseURL(_ release: PreinstalledImageManifest.Release) throws -> URL {
        guard var components = URLComponents(string: "https://github.com") else { throw PreparationError.invalidManifest("Invalid release URL.") }
        components.path = "/\(release.repository)/releases/download/\(release.tag)"
        guard let url = components.url else { throw PreparationError.invalidManifest("Invalid release URL.") }
        return url
    }

    nonisolated private static func cacheDirectory(itemID: String, tag: String) throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "EZVM/PreinstalledImages/\(itemID)/\(tag)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated private static func requireAvailableSpace(at url: URL, minimumBytes: Int64) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage, available >= minimumBytes else {
            throw PreparationError.validation("Omarchy requires at least 15 GB of available disk space.")
        }
    }

    nonisolated private static func verify(_ url: URL, size: Int64, sha256 expected: String) async throws {
        try await Task.detached {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard Int64(values.fileSize ?? -1) == size else { throw PreparationError.validation("Size mismatch for \(url.lastPathComponent).") }
            guard try VMPreinstalledImageInstaller.sha256(of: url) == expected.lowercased() else {
                throw PreparationError.validation("Checksum mismatch for \(url.lastPathComponent).")
            }
        }.value
    }

    nonisolated private static func matches(_ url: URL, size: Int64, sha256: String) async -> Bool {
        await Task.detached {
            guard let actualSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(actualSize) == size else { return false }
            return (try? VMPreinstalledImageInstaller.sha256(of: url)) == sha256.lowercased()
        }.value
    }

    nonisolated private static func thumbnailMatches(
        _ url: URL?,
        metadata: PreinstalledImageManifest.Thumbnail?
    ) async -> Bool {
        guard let metadata else { return true }
        guard let url else { return false }
        return await matches(url, size: metadata.size, sha256: metadata.sha256)
    }

    nonisolated private static func concatenate(
        parts: [URL],
        to output: URL,
        expectedSize: Int64,
        expectedSHA256: String,
        cancellationFlag: VMOperationCancellationFlag
    ) async throws {
        try await Task.detached {
            defer {
                if cancellationFlag.isCancelled { try? FileManager.default.removeItem(at: output) }
            }
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let writer = try FileHandle(forWritingTo: output)
            defer { try? writer.close() }
            var hasher = SHA256()
            var total: Int64 = 0
            for part in parts {
                let reader = try FileHandle(forReadingFrom: part)
                defer { try? reader.close() }
                while true {
                    if cancellationFlag.isCancelled { throw CancellationError() }
                    let data = try reader.read(upToCount: 4 * 1024 * 1024) ?? Data()
                    guard !data.isEmpty else { break }
                    try writer.write(contentsOf: data)
                    hasher.update(data: data)
                    total += Int64(data.count)
                }
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard total == expectedSize, digest == expectedSHA256.lowercased() else {
                throw PreparationError.validation("The complete compressed image failed verification.")
            }
        }.value
    }

    nonisolated private static func decodeSparseGzip(
        _ archive: URL,
        to output: URL,
        expectedSize: UInt64,
        cancellationFlag: VMOperationCancellationFlag
    ) async throws {
        try await Task.detached {
            try? FileManager.default.removeItem(at: output)
            defer {
                if cancellationFlag.isCancelled { try? FileManager.default.removeItem(at: output) }
            }
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-dc", archive.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            do {
                try VMPreinstalledSparseStreamDecoder.decode(
                    from: pipe.fileHandleForReading,
                    to: output,
                    expectedSize: expectedSize,
                    shouldCancel: { cancellationFlag.isCancelled }
                )
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw PreparationError.validation("The compressed image could not be decoded.") }
            } catch {
                process.terminate()
                throw error
            }
        }.value
    }

    private enum PreparationError: LocalizedError {
        case invalidManifest(String), download(String), validation(String)
        var errorDescription: String? {
            switch self {
            case .invalidManifest(let value), .download(let value), .validation(let value): value
            }
        }
    }
}

private extension String {
    var isSHA256: Bool { count == 64 && allSatisfy { $0.isHexDigit && !$0.isUppercase } }
    var isSafeAssetName: Bool {
        !isEmpty && unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }
    }
}


struct CreatePhaseCreatingView: View {
    @Environment(VMCreateViewStateObject.self) var formData

    @State private var showDetails = false

    var body: some View {
        VStack {
            Image(systemName: formData.creationStage == "Ready" ? "checkmark.circle.fill" : "shippingbox.and.arrow.backward")
                .font(.system(size: 42))
                .foregroundStyle(formData.creationStage == "Ready" ? Color.green : Color.accentColor)

            Text(formData.creationStage)
                .font(.title2.weight(.semibold))

            Text("EZVM will download the selected image if needed, then create and install your virtual machine. You can leave this window open and wait once.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)

            // current activity headline, so the user does not have to read logs
            HStack(spacing: 12) {
                if formData.isCreating {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(formData.statusText)
                    .lineLimit(2)
                Spacer()
            }

            HStack(spacing: 12) {
                Text("\(String(format: "%.0f", 100 * formData.installingProgress))%")
                    .font(.caption)
                ProgressView(value: 100 * formData.installingProgress, total: 100)
            }

            DisclosureGroup("Installation details", isExpanded: $showDetails) {
                List {
                    ForEach(formData.logs) { item in
                        HStack {
                            Text(item.time)
                                .foregroundStyle(.secondary)
                            Text(item.log)
                                .lineLimit(0)
                                .multilineTextAlignment(.leading)
                        }
                        .font(.caption)
                    }
                }
                .frame(minHeight: 180)
            }

            Spacer()
        }
        .padding(24)
        .onChange(of: formData.statusText) {
            // surface the full log as soon as something goes wrong
            if formData.statusText.hasPrefix("❌") {
                showDetails = true
            }
        }
    }
}

struct CreatePhaseCreatingView_Previews: PreviewProvider {
    static var previews: some View {
        let formData = VMCreateViewStateObject()
        CreatePhaseCreatingView()
            .environment(formData)
    }
}


#endif
