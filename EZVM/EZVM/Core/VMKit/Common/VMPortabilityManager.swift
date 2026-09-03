import CryptoKit
import Foundation

struct VMPortableFile: Codable, Equatable {
    let relativePath: String
    let size: UInt64
    let sha256: String
}

struct VMExportManifest: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let createdAt: Date
    let sourceBundleName: String
    let minimumMacOSMajorVersion: Int
    let architecture: String
    let files: [VMPortableFile]
}

struct VMPortabilityEstimate: Equatable {
    let logicalBytes: UInt64
    let allocatedBytes: UInt64
    let availableBytes: Int64?

    var requiredBytes: UInt64 {
        // Copies preserve sparse extents on APFS. Keep a bounded margin for
        // directory metadata, manifests, and allocation rounding.
        let margin = max(UInt64(64 * 1_024 * 1_024), allocatedBytes / 20)
        return allocatedBytes.addingReportingOverflow(margin).overflow
            ? UInt64.max
            : allocatedBytes + margin
    }

    var hasEnoughSpace: Bool {
        guard let availableBytes else { return true }
        return availableBytes >= 0 && UInt64(availableBytes) >= requiredBytes
    }
}

enum VMImportIdentityMode: Equatable {
    /// Import as an independent copy. Runtime history and the source identity
    /// are discarded so both machines can safely coexist.
    case copy(machineIdentifierData: Data, name: String)
    /// Restore the exported machine as the same logical machine.
    case restore
}

enum VMPortabilityManager {
    static let exportExtension = "ezvmexport"
    static let payloadDirectoryName = "Machine.ezvm"
    static let manifestFileName = "manifest.json"
    private static let excludedCloneNames: Set<String> = [
        "MachineState.vzvmsave", "MachineState.vzvmsave.pending",
        ".restore-staging", ".restore-backup", ".restore-transaction.json"
    ]

    static func estimate(sourceURL: URL, destinationParent: URL, availableBytes override: Int64? = nil) throws -> VMPortabilityEstimate {
        let files = try regularFiles(in: sourceURL)
        let logical = saturatingSum(files.map(\.size))
        let allocated = saturatingSum(files.map(\.allocatedSize))
        let available = override ?? (try? destinationParent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage)
        return VMPortabilityEstimate(logicalBytes: logical, allocatedBytes: allocated, availableBytes: available)
    }

    static func clone(
        sourceURL: URL,
        destinationURL: URL,
        newName: String,
        machineIdentifierData: Data,
        availableCapacityBytes: Int64? = nil
    ) -> VMOSResultVoid {
        guard !machineIdentifierData.isEmpty else { return .failure("Could not generate a new machine identifier.") }
        guard !isInside(destinationURL, parent: sourceURL) else {
            return .failure("The clone destination cannot be inside the source machine bundle.")
        }
        do {
            let estimate = try estimate(
                sourceURL: sourceURL,
                destinationParent: destinationURL.deletingLastPathComponent(),
                availableBytes: availableCapacityBytes
            )
            guard estimate.hasEnoughSpace else {
                return .failure(insufficientSpaceMessage(operation: "clone", estimate: estimate))
            }
        } catch { return .failure("Could not estimate clone storage: \(error.localizedDescription)") }
        return transactCopy(sourceURL: sourceURL, destinationURL: destinationURL) { staging in
            for name in excludedCloneNames {
                try? FileManager.default.removeItem(at: staging.appendingPathComponent(name))
            }
            // Snapshot histories contain historical hardware identities. A clone
            // starts a new history so restoring it can never resurrect the source ID.
            try? FileManager.default.removeItem(at: staging.appendingPathComponent("Snapshots"))
            try machineIdentifierData.write(
                to: staging.appendingPathComponent("MachineIdentifier"),
                options: .atomic
            )
            try rewriteMachineName(at: staging.appendingPathComponent("config.json"), name: newName)
        }
    }

    static func exportMachine(
        sourceURL: URL,
        destinationURL: URL,
        availableCapacityBytes: Int64? = nil
    ) -> VMOSResultVoid {
        guard destinationURL.pathExtension == exportExtension else {
            return .failure("The export destination must end in .\(exportExtension).")
        }
        guard !isInside(destinationURL, parent: sourceURL) else {
            return .failure("The export destination cannot be inside the source machine bundle.")
        }
        guard FileManager.default.fileExists(atPath: sourceURL.appendingPathComponent("config.json").path) else {
            return .failure("The source machine has no config.json.")
        }
        do {
            let estimate = try estimate(
                sourceURL: sourceURL,
                destinationParent: destinationURL.deletingLastPathComponent(),
                availableBytes: availableCapacityBytes
            )
            guard estimate.hasEnoughSpace else {
                return .failure(insufficientSpaceMessage(operation: "export", estimate: estimate))
            }
        } catch { return .failure("Could not estimate export storage: \(error.localizedDescription)") }
        return transactDirectory(destinationURL: destinationURL) { staging in
            let payload = staging.appendingPathComponent(payloadDirectoryName, isDirectory: true)
            try copyTree(from: sourceURL, to: payload)
            let files = try portableFiles(in: payload)
            let manifest = VMExportManifest(
                schemaVersion: VMExportManifest.currentSchemaVersion,
                createdAt: Date(),
                sourceBundleName: sourceURL.lastPathComponent,
                minimumMacOSMajorVersion: 26,
                architecture: "arm64",
                files: files
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(
                to: staging.appendingPathComponent(manifestFileName),
                options: .atomic
            )
        }
    }

    static func validateExport(at exportURL: URL) -> VMOSResult<VMExportManifest, String> {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(
                VMExportManifest.self,
                from: Data(contentsOf: exportURL.appendingPathComponent(manifestFileName))
            )
            guard manifest.schemaVersion == VMExportManifest.currentSchemaVersion else {
                return .failure("Unsupported export schema version \(manifest.schemaVersion).")
            }
            guard manifest.architecture == "arm64" else {
                return .failure("This export requires the \(manifest.architecture) architecture.")
            }
            guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= manifest.minimumMacOSMajorVersion else {
                return .failure("This export requires macOS \(manifest.minimumMacOSMajorVersion) or later.")
            }
            let payload = exportURL.appendingPathComponent(payloadDirectoryName, isDirectory: true)
            let actual = try portableFiles(in: payload)
            guard actual == manifest.files else {
                return .failure(describeMismatch(expected: manifest.files, actual: actual))
            }
            guard FileManager.default.fileExists(atPath: payload.appendingPathComponent("config.json").path) else {
                return .failure("The exported machine has no config.json.")
            }
            return .success(manifest)
        } catch {
            return .failure("The export is unreadable: \(error.localizedDescription)")
        }
    }

    static func importMachine(
        exportURL: URL,
        destinationURL: URL,
        identityMode: VMImportIdentityMode,
        availableCapacityBytes: Int64? = nil
    ) -> VMOSResultVoid {
        guard !isInside(destinationURL, parent: exportURL) else {
            return .failure("The import destination cannot be inside the export package.")
        }
        switch validateExport(at: exportURL) {
        case .failure(let error): return .failure(error)
        case .success: break
        }
        do {
            let payload = exportURL.appendingPathComponent(payloadDirectoryName, isDirectory: true)
            let estimate = try estimate(
                sourceURL: payload,
                destinationParent: destinationURL.deletingLastPathComponent(),
                availableBytes: availableCapacityBytes
            )
            guard estimate.hasEnoughSpace else {
                return .failure(insufficientSpaceMessage(operation: "import", estimate: estimate))
            }
        } catch { return .failure("Could not estimate import storage: \(error.localizedDescription)") }
        return transactCopy(
            sourceURL: exportURL.appendingPathComponent(payloadDirectoryName, isDirectory: true),
            destinationURL: destinationURL,
            mutation: { staging in
                guard case .copy(let identifier, let name) = identityMode else { return }
                guard !identifier.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
                for excludedName in excludedCloneNames {
                    try? FileManager.default.removeItem(at: staging.appendingPathComponent(excludedName))
                }
                try? FileManager.default.removeItem(at: staging.appendingPathComponent("Snapshots"))
                try identifier.write(to: staging.appendingPathComponent("MachineIdentifier"), options: .atomic)
                try rewriteMachineName(at: staging.appendingPathComponent("config.json"), name: name)
            }
        )
    }

    private static func transactCopy(
        sourceURL: URL,
        destinationURL: URL,
        mutation: (URL) throws -> Void
    ) -> VMOSResultVoid {
        transactDirectory(destinationURL: destinationURL) { staging in
            try copyContents(from: sourceURL, to: staging)
            try mutation(staging)
            guard FileManager.default.fileExists(atPath: staging.appendingPathComponent("config.json").path) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
        }
    }

    static func saturatingSum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { total, value in
            let result = total.addingReportingOverflow(value)
            return result.overflow ? UInt64.max : result.partialValue
        }
    }

    private static func insufficientSpaceMessage(
        operation: String,
        estimate: VMPortabilityEstimate
    ) -> String {
        let required = ByteCountFormatter.string(fromByteCount: Int64(clamping: estimate.requiredBytes), countStyle: .file)
        let available = estimate.availableBytes.map {
            ByteCountFormatter.string(fromByteCount: max(0, $0), countStyle: .file)
        } ?? "unknown"
        return "There is not enough free disk space to \(operation) this machine. Required: \(required); available: \(available)."
    }

    private static func transactDirectory(
        destinationURL: URL,
        operation: (URL) throws -> Void
    ) -> VMOSResultVoid {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destinationURL.path) else {
            return .failure("The destination already exists.")
        }
        let parent = destinationURL.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).partial")
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            try operation(staging)
            try fm.moveItem(at: staging, to: destinationURL)
            return .success
        } catch {
            try? fm.removeItem(at: staging)
            return .failure("The operation was rolled back: \(error.localizedDescription)")
        }
    }

    private static func copyTree(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try copyContents(from: source, to: destination)
    }

    private static func copyContents(from source: URL, to destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        for item in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try FileManager.default.copyItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
    }

    private static func rewriteMachineName(at configURL: URL, name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        guard object != nil else { throw CocoaError(.fileReadCorruptFile) }
        object?["name"] = name
        try JSONSerialization.data(withJSONObject: object as Any, options: [.prettyPrinted, .sortedKeys])
            .write(to: configURL, options: .atomic)
    }

    private static func regularFiles(in root: URL) throws -> [(url: URL, relativePath: String, size: UInt64, allocatedSize: UInt64)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else {
            throw CocoaError(.fileReadUnknown)
        }
        var result: [(url: URL, relativePath: String, size: UInt64, allocatedSize: UInt64)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            let relative = url.standardizedFileURL.pathComponents
                .dropFirst(root.standardizedFileURL.pathComponents.count).joined(separator: "/")
            if values.isSymbolicLink == true { throw CocoaError(.fileReadUnsupportedScheme) }
            if values.isRegularFile == true {
                let logicalSize = UInt64(values.fileSize ?? 0)
                result.append((url, relative, logicalSize, UInt64(values.fileAllocatedSize ?? values.fileSize ?? 0)))
            }
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private static func portableFiles(in root: URL) throws -> [VMPortableFile] {
        try regularFiles(in: root).map {
            VMPortableFile(relativePath: $0.relativePath, size: $0.size, sha256: try sha256(of: $0.url))
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func describeMismatch(expected: [VMPortableFile], actual: [VMPortableFile]) -> String {
        let expectedMap = Dictionary(uniqueKeysWithValues: expected.map { ($0.relativePath, $0) })
        let actualMap = Dictionary(uniqueKeysWithValues: actual.map { ($0.relativePath, $0) })
        if let missing = expectedMap.keys.first(where: { actualMap[$0] == nil }) { return "Export file is missing: \(missing)." }
        if let extra = actualMap.keys.first(where: { expectedMap[$0] == nil }) { return "Export contains an unexpected file: \(extra)." }
        if let changed = expectedMap.keys.first(where: { expectedMap[$0] != actualMap[$0] }) { return "Export file is corrupt or truncated: \(changed)." }
        return "The export manifest does not match its payload."
    }

    private static func isInside(_ candidate: URL, parent: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let parentComponents = parent.standardizedFileURL.pathComponents
        return candidateComponents.count > parentComponents.count
            && Array(candidateComponents.prefix(parentComponents.count)) == parentComponents
    }
}
