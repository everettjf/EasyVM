import CryptoKit
import EZVMCore
import Foundation
import Virtualization

enum FactoryToolError: LocalizedError {
    case usage
    case existingOutput(String)
    case invalidPrivateKey
    case invalidImagePart(String)
    case invalidLogicalSize
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .usage:
            """
            usage:
              omarchy-factory-tool generate-key <private-key> <public-key>
              omarchy-factory-tool sign <image.asif> <image-url> <version> <omarchy-revision> <agent-version> <key-id> <private-key> <manifest.json>
              omarchy-factory-tool sign-parts <image.asif> <version> <omarchy-revision> <agent-version> <key-id> <private-key> <manifest.json> <part-url> <part-file> [<part-url> <part-file> ...]
              omarchy-factory-tool verify <manifest.json> <image.asif> <public-key>
              omarchy-factory-tool prepare-workspace <manifest.json> <image.asif> <public-key> <application-support-root>
              omarchy-factory-tool decode-sparse-gzip <archive.gz> <logical-size> <output.raw>
            """
        case .existingOutput(let path): "Refusing to overwrite existing output: \(path)"
        case .invalidPrivateKey: "The signing key is not a raw Ed25519 private key."
        case .invalidImagePart(let reason): "The Factory image parts are invalid: \(reason)"
        case .invalidLogicalSize: "The sparse image logical size is invalid."
        case .decompressionFailed: "The compressed sparse image could not be decoded."
        }
    }
}

@main
enum OmarchyFactoryTool {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(error is FactoryToolError ? 64 : 1)
        }
    }

    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else { throw FactoryToolError.usage }
        switch command {
        case "generate-key":
            guard arguments.count == 3 else { throw FactoryToolError.usage }
            let privateURL = URL(filePath: arguments[1])
            let publicURL = URL(filePath: arguments[2])
            try requireAbsent([privateURL, publicURL])
            let key = Curve25519.Signing.PrivateKey()
            try key.rawRepresentation.write(to: privateURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateURL.path)
            try key.publicKey.rawRepresentation.write(to: publicURL, options: [.atomic])
        case "sign":
            guard arguments.count == 9,
                  let imageURL = URL(string: arguments[2]), imageURL.scheme == "https" else {
                throw FactoryToolError.usage
            }
            let image = URL(filePath: arguments[1])
            let privateKeyData = try Data(contentsOf: URL(filePath: arguments[7]))
            guard let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData) else {
                throw FactoryToolError.invalidPrivateKey
            }
            let output = URL(filePath: arguments[8])
            try requireAbsent([output])
            let values = try image.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
                throw VMOmarchyFactoryValidationError.imageMissing
            }
            let payload = VMOmarchyFactoryManifest.Payload(
                schemaVersion: 1,
                imageVersion: arguments[3],
                imageURL: imageURL,
                imageByteCount: UInt64(size),
                imageSHA256: try digest(image),
                architecture: "arm64",
                omarchyRevision: arguments[4],
                guestAgentVersion: arguments[5],
                guestCapabilities: VMOmarchyProfile.production.factoryGuestCapabilities
            )
            let signature = try privateKey.signature(for: VMOmarchyFactoryValidator.canonicalPayload(payload))
            let manifest = VMOmarchyFactoryManifest(
                payload: payload,
                keyID: arguments[6],
                signature: signature.base64EncodedString()
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(manifest).write(to: output, options: [.atomic])
        case "sign-parts":
            guard arguments.count >= 12, arguments.count.isMultiple(of: 2) else {
                throw FactoryToolError.usage
            }
            let image = URL(filePath: arguments[1])
            let output = URL(filePath: arguments[7])
            try requireAbsent([output])
            let privateKeyData = try Data(contentsOf: URL(filePath: arguments[6]))
            guard let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData) else {
                throw FactoryToolError.invalidPrivateKey
            }
            let imageSize = try regularFileSize(image)
            var parts: [VMOmarchyFactoryManifest.ImagePart] = []
            var partFiles: [URL] = []
            for index in stride(from: 8, to: arguments.count, by: 2) {
                guard let remoteURL = URL(string: arguments[index]), remoteURL.scheme == "https" else {
                    throw FactoryToolError.invalidImagePart("every part URL must use HTTPS")
                }
                let localURL = URL(filePath: arguments[index + 1])
                let size = try regularFileSize(localURL)
                guard size > 0, size <= VMOmarchyFactoryValidator.maximumPartBytes else {
                    throw FactoryToolError.invalidImagePart("every part must be between 1 byte and 1900 MiB")
                }
                parts.append(.init(url: remoteURL, byteCount: size, sha256: try digest(localURL)))
                partFiles.append(localURL)
            }
            guard Set(parts.map(\.url)).count == parts.count else {
                throw FactoryToolError.invalidImagePart("part URLs must be unique")
            }
            let total = try parts.reduce(UInt64(0)) { partial, part in
                let (sum, overflow) = partial.addingReportingOverflow(part.byteCount)
                guard !overflow else { throw FactoryToolError.invalidImagePart("part sizes overflow") }
                return sum
            }
            let imageDigest = try digest(image)
            guard total == imageSize, try digest(partFiles) == imageDigest else {
                throw FactoryToolError.invalidImagePart("concatenated parts do not reproduce the Factory image")
            }
            let payload = VMOmarchyFactoryManifest.Payload(
                schemaVersion: 2,
                imageVersion: arguments[2],
                imageParts: parts,
                imageByteCount: imageSize,
                imageSHA256: imageDigest,
                architecture: "arm64",
                omarchyRevision: arguments[3],
                guestAgentVersion: arguments[4],
                guestCapabilities: VMOmarchyProfile.production.factoryGuestCapabilities
            )
            let signature = try privateKey.signature(for: VMOmarchyFactoryValidator.canonicalPayload(payload))
            let manifest = VMOmarchyFactoryManifest(
                payload: payload,
                keyID: arguments[5],
                signature: signature.base64EncodedString()
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(manifest).write(to: output, options: [.atomic])
        case "verify":
            guard arguments.count == 4 else { throw FactoryToolError.usage }
            let manifest = try loadManifest(URL(filePath: arguments[1]))
            let publicKey = try Data(contentsOf: URL(filePath: arguments[3]))
            let profile = verificationProfile(signingKeyID: manifest.keyID)
            try VMOmarchyFactoryValidator.validateManifest(manifest, profile: profile, publicKey: publicKey)
            try VMOmarchyFactoryValidator.validateImage(at: URL(filePath: arguments[2]), manifest: manifest)
        case "prepare-workspace":
            guard arguments.count == 5 else { throw FactoryToolError.usage }
            let manifest = try loadManifest(URL(filePath: arguments[1]))
            let image = URL(filePath: arguments[2])
            let publicKey = try Data(contentsOf: URL(filePath: arguments[3]))
            let profile = verificationProfile(signingKeyID: manifest.keyID)
            try VMOmarchyFactoryValidator.validateManifest(manifest, profile: profile, publicKey: publicKey)
            try VMOmarchyFactoryValidator.validateImage(at: image, manifest: manifest)
            let metadata = try JSONEncoder().encode(VMOmarchyWorkspaceMetadata(
                productID: profile.productID,
                createdAt: Date(),
                factoryImageVersion: manifest.payload.imageVersion,
                omarchyRevision: manifest.payload.omarchyRevision,
                guestAgentVersion: manifest.payload.guestAgentVersion,
                guestCapabilities: manifest.payload.guestCapabilities.sorted()
            ))
            try VMOmarchyWorkspaceManager(
                layout: .init(applicationSupportRoot: URL(filePath: arguments[4]))
            ).prepare(
                factoryDisk: image,
                configuration: metadata,
                machineIdentifier: VZGenericMachineIdentifier().dataRepresentation
            )
        case "decode-sparse-gzip":
            guard arguments.count == 4,
                  let logicalSize = UInt64(arguments[2]), logicalSize > 0 else {
                throw FactoryToolError.invalidLogicalSize
            }
            let archive = URL(filePath: arguments[1])
            let output = URL(filePath: arguments[3])
            try requireAbsent([output])
            let values = try archive.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw FactoryToolError.decompressionFailed
            }
            FileManager.default.createFile(atPath: output.path, contents: nil)
            do {
                try decodeSparseGzip(archive, to: output, logicalSize: logicalSize)
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        default:
            throw FactoryToolError.usage
        }
    }

    private static func decodeSparseGzip(
        _ archive: URL,
        to output: URL,
        logicalSize: UInt64
    ) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/gzip")
        process.arguments = ["-dc", archive.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        do {
            try VMPreinstalledSparseStreamDecoder.decode(
                from: pipe.fileHandleForReading,
                to: output,
                expectedSize: logicalSize
            )
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw FactoryToolError.decompressionFailed
            }
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
    }

    private static func requireAbsent(_ urls: [URL]) throws {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            throw FactoryToolError.existingOutput(url.path)
        }
    }

    private static func loadManifest(_ url: URL) throws -> VMOmarchyFactoryManifest {
        try JSONDecoder().decode(VMOmarchyFactoryManifest.self, from: Data(contentsOf: url))
    }

    private static func regularFileSize(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0 else {
            throw VMOmarchyFactoryValidationError.imageMissing
        }
        return UInt64(size)
    }

    private static func verificationProfile(signingKeyID: String) -> VMOmarchyProfile {
        let production = VMOmarchyProfile.production
        return VMOmarchyProfile(
            schemaVersion: production.schemaVersion,
            productID: production.productID,
            minimumHostMajorVersion: production.minimumHostMajorVersion,
            diskCapacityBytes: production.diskCapacityBytes,
            resourceTiers: production.resourceTiers,
            requiredGuestCapabilities: production.requiredGuestCapabilities,
            factoryImage: .init(
                manifestURL: production.factoryImage.manifestURL,
                signingKeyID: signingKeyID,
                architecture: production.factoryImage.architecture,
                maximumDownloadBytes: production.factoryImage.maximumDownloadBytes
            )
        )
    }

    private static func digest(_ url: URL) throws -> String {
        try digest([url])
    }

    private static func digest(_ urls: [URL]) throws -> String {
        var hash = SHA256()
        for url in urls {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while true {
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                if data.isEmpty { break }
                hash.update(data: data)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
