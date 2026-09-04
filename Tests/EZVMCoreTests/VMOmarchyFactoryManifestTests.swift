import CryptoKit
import XCTest
@testable import EZVMCore

final class VMOmarchyFactoryManifestTests: XCTestCase {
    func testSignedManifestAndMatchingImageAreAccepted() throws {
        let image = Data("verified Omarchy factory".utf8)
        let imageURL = FileManager.default.temporaryDirectory
            .appending(path: "omarchy-factory-\(UUID().uuidString).asif")
        try image.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let key = Curve25519.Signing.PrivateKey()
        let payload = makePayload(image: image)
        let signature = try key.signature(for: VMOmarchyFactoryValidator.canonicalPayload(payload))
        let manifest = VMOmarchyFactoryManifest(
            payload: payload,
            keyID: VMOmarchyProfile.production.factoryImage.signingKeyID,
            signature: signature.base64EncodedString()
        )

        try VMOmarchyFactoryValidator.validateManifest(
            manifest,
            profile: .production,
            publicKey: key.publicKey.rawRepresentation
        )
        try VMOmarchyFactoryValidator.validateImage(at: imageURL, manifest: manifest)
    }

    func testTamperingInvalidatesManifestSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = makePayload(image: Data("original".utf8))
        let signature = try key.signature(for: VMOmarchyFactoryValidator.canonicalPayload(payload))
        let changed = VMOmarchyFactoryManifest.Payload(
            schemaVersion: payload.schemaVersion,
            imageVersion: "changed",
            imageURL: payload.imageURL,
            imageByteCount: payload.imageByteCount,
            imageSHA256: payload.imageSHA256,
            architecture: payload.architecture,
            omarchyRevision: payload.omarchyRevision,
            guestAgentVersion: payload.guestAgentVersion,
            guestCapabilities: payload.guestCapabilities
        )
        XCTAssertThrowsError(try VMOmarchyFactoryValidator.validateManifest(
            .init(payload: changed, keyID: VMOmarchyProfile.production.factoryImage.signingKeyID, signature: signature.base64EncodedString()),
            profile: .production,
            publicKey: key.publicKey.rawRepresentation
        )) { error in
            XCTAssertEqual(error as? VMOmarchyFactoryValidationError, .invalidSignature)
        }
    }

    func testManifestMissingRequiredGuestCapabilityIsRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let original = makePayload(image: Data("factory".utf8))
        let payload = VMOmarchyFactoryManifest.Payload(
            schemaVersion: original.schemaVersion,
            imageVersion: original.imageVersion,
            imageURL: original.imageURL,
            imageByteCount: original.imageByteCount,
            imageSHA256: original.imageSHA256,
            architecture: original.architecture,
            omarchyRevision: original.omarchyRevision,
            guestAgentVersion: original.guestAgentVersion,
            guestCapabilities: ["shutdown-v1"]
        )
        let signature = try key.signature(for: VMOmarchyFactoryValidator.canonicalPayload(payload))
        XCTAssertThrowsError(try VMOmarchyFactoryValidator.validateManifest(
            .init(
                payload: payload,
                keyID: VMOmarchyProfile.production.factoryImage.signingKeyID,
                signature: signature.base64EncodedString()
            ),
            profile: .production,
            publicKey: key.publicKey.rawRepresentation
        )) { error in
            XCTAssertEqual(error as? VMOmarchyFactoryValidationError, .invalidManifest)
        }
    }

    func testChangedImageIsRejected() throws {
        let expected = Data("expected".utf8)
        let imageURL = FileManager.default.temporaryDirectory
            .appending(path: "omarchy-factory-\(UUID().uuidString).asif")
        try Data("modified".utf8).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let manifest = VMOmarchyFactoryManifest(
            payload: makePayload(image: expected),
            keyID: "unused",
            signature: "unused"
        )
        XCTAssertThrowsError(try VMOmarchyFactoryValidator.validateImage(at: imageURL, manifest: manifest)) { error in
            XCTAssertEqual(error as? VMOmarchyFactoryValidationError, .imageDigestMismatch)
        }
    }

    private func makePayload(image: Data) -> VMOmarchyFactoryManifest.Payload {
        let digest = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        return .init(
            schemaVersion: 1,
            imageVersion: "2026.09-test",
            imageURL: URL(string: "https://download.ezvm.app/omarchy/test.asif")!,
            imageByteCount: UInt64(image.count),
            imageSHA256: digest,
            architecture: "arm64",
            omarchyRevision: "test-revision",
            guestAgentVersion: "1.0.0",
            guestCapabilities: VMOmarchyProfile.production.factoryGuestCapabilities
        )
    }
}
