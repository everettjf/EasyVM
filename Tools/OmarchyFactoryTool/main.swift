import CryptoKit
import EZVMCore
import Foundation

enum FactoryToolError: LocalizedError {
    case usage
    case existingOutput(String)
    case invalidPrivateKey

    var errorDescription: String? {
        switch self {
        case .usage:
            """
            usage:
              omarchy-factory-tool generate-key <private-key> <public-key>
              omarchy-factory-tool sign <image.asif> <image-url> <version> <omarchy-revision> <agent-version> <key-id> <private-key> <manifest.json>
              omarchy-factory-tool verify <manifest.json> <image.asif> <public-key>
            """
        case .existingOutput(let path): "Refusing to overwrite existing output: \(path)"
        case .invalidPrivateKey: "The signing key is not a raw Ed25519 private key."
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
                guestCapabilities: VMOmarchyProfile.production.requiredGuestCapabilities.sorted()
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
        case "verify":
            guard arguments.count == 4 else { throw FactoryToolError.usage }
            let manifest = try JSONDecoder().decode(
                VMOmarchyFactoryManifest.self,
                from: Data(contentsOf: URL(filePath: arguments[1]))
            )
            let publicKey = try Data(contentsOf: URL(filePath: arguments[3]))
            let production = VMOmarchyProfile.production
            let profile = VMOmarchyProfile(
                schemaVersion: production.schemaVersion,
                productID: production.productID,
                minimumHostMajorVersion: production.minimumHostMajorVersion,
                diskCapacityBytes: production.diskCapacityBytes,
                resourceTiers: production.resourceTiers,
                requiredGuestCapabilities: production.requiredGuestCapabilities,
                factoryImage: .init(
                    manifestURL: production.factoryImage.manifestURL,
                    signingKeyID: manifest.keyID,
                    architecture: production.factoryImage.architecture,
                    maximumDownloadBytes: production.factoryImage.maximumDownloadBytes
                )
            )
            try VMOmarchyFactoryValidator.validateManifest(manifest, profile: profile, publicKey: publicKey)
            try VMOmarchyFactoryValidator.validateImage(at: URL(filePath: arguments[2]), manifest: manifest)
        default:
            throw FactoryToolError.usage
        }
    }

    private static func requireAbsent(_ urls: [URL]) throws {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            throw FactoryToolError.existingOutput(url.path)
        }
    }

    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
