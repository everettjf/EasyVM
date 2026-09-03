import CryptoKit
import Foundation

public struct VMOmarchyFactoryManifest: Codable, Equatable {
    public struct Payload: Codable, Equatable {
        public let schemaVersion: Int
        public let imageVersion: String
        public let imageURL: URL
        public let imageByteCount: UInt64
        public let imageSHA256: String
        public let architecture: String
        public let omarchyRevision: String
        public let guestAgentVersion: String
        public let guestCapabilities: [String]

        public init(
            schemaVersion: Int,
            imageVersion: String,
            imageURL: URL,
            imageByteCount: UInt64,
            imageSHA256: String,
            architecture: String,
            omarchyRevision: String,
            guestAgentVersion: String,
            guestCapabilities: [String]
        ) {
            self.schemaVersion = schemaVersion
            self.imageVersion = imageVersion
            self.imageURL = imageURL
            self.imageByteCount = imageByteCount
            self.imageSHA256 = imageSHA256
            self.architecture = architecture
            self.omarchyRevision = omarchyRevision
            self.guestAgentVersion = guestAgentVersion
            self.guestCapabilities = guestCapabilities
        }
    }

    public let payload: Payload
    public let keyID: String
    public let signature: String

    public init(payload: Payload, keyID: String, signature: String) {
        self.payload = payload
        self.keyID = keyID
        self.signature = signature
    }
}

public enum VMOmarchyFactoryValidationError: Error, Equatable {
    case invalidManifest
    case unexpectedSigningKey
    case invalidPublicKey
    case invalidSignature
    case imageMissing
    case imageSizeMismatch
    case imageDigestMismatch
}

public enum VMOmarchyFactoryValidator {
    public static func validateManifest(
        _ manifest: VMOmarchyFactoryManifest,
        profile: VMOmarchyProfile,
        publicKey: Data
    ) throws {
        let payload = manifest.payload
        guard payload.schemaVersion == 1,
              payload.architecture == profile.factoryImage.architecture,
              payload.imageURL.scheme == "https",
              payload.imageByteCount > 0,
              payload.imageByteCount <= profile.factoryImage.maximumDownloadBytes,
              payload.imageSHA256.count == 64,
              payload.imageSHA256.allSatisfy({ $0.isHexDigit }),
              !payload.imageVersion.isEmpty,
              !payload.omarchyRevision.isEmpty,
              !payload.guestAgentVersion.isEmpty,
              Set(payload.guestCapabilities).count == payload.guestCapabilities.count,
              Set(payload.guestCapabilities).isSuperset(of: profile.requiredGuestCapabilities) else {
            throw VMOmarchyFactoryValidationError.invalidManifest
        }
        guard manifest.keyID == profile.factoryImage.signingKeyID else {
            throw VMOmarchyFactoryValidationError.unexpectedSigningKey
        }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            throw VMOmarchyFactoryValidationError.invalidPublicKey
        }
        guard let signature = Data(base64Encoded: manifest.signature) else {
            throw VMOmarchyFactoryValidationError.invalidSignature
        }
        guard key.isValidSignature(signature, for: try canonicalPayload(payload)) else {
            throw VMOmarchyFactoryValidationError.invalidSignature
        }
    }

    public static func validateImage(
        at imageURL: URL,
        manifest: VMOmarchyFactoryManifest,
        fileManager: FileManager = .default
    ) throws {
        let values: URLResourceValues
        do {
            values = try imageURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
        } catch {
            throw VMOmarchyFactoryValidationError.imageMissing
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VMOmarchyFactoryValidationError.imageMissing
        }
        guard let fileSize = values.fileSize,
              fileSize >= 0,
              UInt64(fileSize) == manifest.payload.imageByteCount else {
            throw VMOmarchyFactoryValidationError.imageSizeMismatch
        }
        guard try sha256(of: imageURL) == manifest.payload.imageSHA256.lowercased() else {
            throw VMOmarchyFactoryValidationError.imageDigestMismatch
        }
    }

    public static func canonicalPayload(_ payload: VMOmarchyFactoryManifest.Payload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
