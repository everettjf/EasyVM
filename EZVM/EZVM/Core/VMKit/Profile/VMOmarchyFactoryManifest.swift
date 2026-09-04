import CryptoKit
import Foundation

public struct VMOmarchyFactoryManifest: Codable, Equatable, Sendable {
    public struct ImagePart: Codable, Equatable, Sendable {
        public let url: URL
        public let byteCount: UInt64
        public let sha256: String

        public init(url: URL, byteCount: UInt64, sha256: String) {
            self.url = url
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    public struct Payload: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let imageVersion: String
        public let imageURL: URL?
        public let imageParts: [ImagePart]?
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
            self.imageParts = nil
            self.imageByteCount = imageByteCount
            self.imageSHA256 = imageSHA256
            self.architecture = architecture
            self.omarchyRevision = omarchyRevision
            self.guestAgentVersion = guestAgentVersion
            self.guestCapabilities = guestCapabilities
        }

        public init(
            schemaVersion: Int,
            imageVersion: String,
            imageParts: [ImagePart],
            imageByteCount: UInt64,
            imageSHA256: String,
            architecture: String,
            omarchyRevision: String,
            guestAgentVersion: String,
            guestCapabilities: [String]
        ) {
            self.schemaVersion = schemaVersion
            self.imageVersion = imageVersion
            self.imageURL = nil
            self.imageParts = imageParts
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
    public static let maximumPartBytes: UInt64 = 1_900 * 1_024 * 1_024

    public static func validateManifest(
        _ manifest: VMOmarchyFactoryManifest,
        profile: VMOmarchyProfile,
        publicKey: Data
    ) throws {
        let payload = manifest.payload
        let validDelivery: Bool
        switch payload.schemaVersion {
        case 1:
            validDelivery = payload.imageURL?.scheme == "https" && payload.imageParts == nil
        case 2:
            let parts = payload.imageParts ?? []
            validDelivery = payload.imageURL == nil
                && (2 ... 32).contains(parts.count)
                && parts.allSatisfy {
                    $0.url.scheme == "https"
                        && $0.byteCount > 0
                        && $0.byteCount <= maximumPartBytes
                        && validDigest($0.sha256)
                }
                && parts.reduce(UInt64(0), { partial, part in
                    let (sum, overflow) = partial.addingReportingOverflow(part.byteCount)
                    return overflow ? UInt64.max : sum
                }) == payload.imageByteCount
                && Set(parts.map(\.url)).count == parts.count
        default:
            validDelivery = false
        }
        guard validDelivery,
              payload.architecture == profile.factoryImage.architecture,
              payload.imageByteCount > 0,
              payload.imageByteCount <= profile.factoryImage.maximumDownloadBytes,
              validDigest(payload.imageSHA256),
              !payload.imageVersion.isEmpty,
              !payload.omarchyRevision.isEmpty,
              !payload.guestAgentVersion.isEmpty,
              Set(payload.guestCapabilities).count == payload.guestCapabilities.count,
              Set(payload.guestCapabilities).isSuperset(of: profile.factoryGuestCapabilities) else {
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

    public static func validatePart(at url: URL, part: VMOmarchyFactoryManifest.ImagePart) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            throw VMOmarchyFactoryValidationError.imageMissing
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VMOmarchyFactoryValidationError.imageMissing
        }
        guard let size = values.fileSize, size >= 0, UInt64(size) == part.byteCount else {
            throw VMOmarchyFactoryValidationError.imageSizeMismatch
        }
        guard try sha256(of: url) == part.sha256.lowercased() else {
            throw VMOmarchyFactoryValidationError.imageDigestMismatch
        }
    }

    public static func canonicalPayload(_ payload: VMOmarchyFactoryManifest.Payload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
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
