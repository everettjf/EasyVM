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
            imageURL: try XCTUnwrap(payload.imageURL),
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
            imageURL: try XCTUnwrap(original.imageURL),
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

    func testLegacySchemaOneCanonicalPayloadDoesNotGainMultipartFields() throws {
        let payload = makePayload(image: Data("legacy".utf8))
        let canonical = try VMOmarchyFactoryValidator.canonicalPayload(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: canonical) as? [String: Any])

        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(object["imageURL"])
        XCTAssertNil(object["imageParts"])
    }

    func testMultipartManifestIsAccepted() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = makeMultipartPayload()
        let manifest = try signedManifest(payload, key: key)

        XCTAssertNoThrow(try VMOmarchyFactoryValidator.validateManifest(
            manifest,
            profile: .production,
            publicKey: key.publicKey.rawRepresentation
        ))
    }

    func testMultipartManifestRejectsOnePart() throws {
        try assertInvalidMultipart { payload in
            .init(
                schemaVersion: 2,
                imageVersion: payload.imageVersion,
                imageParts: [try XCTUnwrap(payload.imageParts?.first)],
                imageByteCount: try XCTUnwrap(payload.imageParts?.first?.byteCount),
                imageSHA256: payload.imageSHA256,
                architecture: payload.architecture,
                omarchyRevision: payload.omarchyRevision,
                guestAgentVersion: payload.guestAgentVersion,
                guestCapabilities: payload.guestCapabilities
            )
        }
    }

    func testMultipartManifestRejectsDuplicateURLs() throws {
        try assertInvalidMultipart { payload in
            let first = try XCTUnwrap(payload.imageParts?.first)
            let second = try XCTUnwrap(payload.imageParts?.last)
            return .init(
                schemaVersion: 2,
                imageVersion: payload.imageVersion,
                imageParts: [first, .init(url: first.url, byteCount: second.byteCount, sha256: second.sha256)],
                imageByteCount: payload.imageByteCount,
                imageSHA256: payload.imageSHA256,
                architecture: payload.architecture,
                omarchyRevision: payload.omarchyRevision,
                guestAgentVersion: payload.guestAgentVersion,
                guestCapabilities: payload.guestCapabilities
            )
        }
    }

    func testMultipartManifestRejectsWrongTotalSize() throws {
        try assertInvalidMultipart { payload in
            .init(
                schemaVersion: 2,
                imageVersion: payload.imageVersion,
                imageParts: try XCTUnwrap(payload.imageParts),
                imageByteCount: payload.imageByteCount + 1,
                imageSHA256: payload.imageSHA256,
                architecture: payload.architecture,
                omarchyRevision: payload.omarchyRevision,
                guestAgentVersion: payload.guestAgentVersion,
                guestCapabilities: payload.guestCapabilities
            )
        }
    }

    func testMultipartManifestRejectsOversizedPart() throws {
        try assertInvalidMultipart { payload in
            var parts = try XCTUnwrap(payload.imageParts)
            parts[0] = .init(
                url: parts[0].url,
                byteCount: VMOmarchyFactoryValidator.maximumPartBytes + 1,
                sha256: parts[0].sha256
            )
            return .init(
                schemaVersion: 2,
                imageVersion: payload.imageVersion,
                imageParts: parts,
                imageByteCount: parts.reduce(0) { $0 + $1.byteCount },
                imageSHA256: payload.imageSHA256,
                architecture: payload.architecture,
                omarchyRevision: payload.omarchyRevision,
                guestAgentVersion: payload.guestAgentVersion,
                guestCapabilities: payload.guestCapabilities
            )
        }
    }

    private func assertInvalidMultipart(
        mutate: (VMOmarchyFactoryManifest.Payload) throws -> VMOmarchyFactoryManifest.Payload
    ) throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = try mutate(makeMultipartPayload())
        let manifest = try signedManifest(payload, key: key)
        XCTAssertThrowsError(try VMOmarchyFactoryValidator.validateManifest(
            manifest,
            profile: .production,
            publicKey: key.publicKey.rawRepresentation
        )) { error in
            XCTAssertEqual(error as? VMOmarchyFactoryValidationError, .invalidManifest)
        }
    }

    private func signedManifest(
        _ payload: VMOmarchyFactoryManifest.Payload,
        key: Curve25519.Signing.PrivateKey
    ) throws -> VMOmarchyFactoryManifest {
        let signature = try key.signature(for: VMOmarchyFactoryValidator.canonicalPayload(payload))
        return .init(
            payload: payload,
            keyID: VMOmarchyProfile.production.factoryImage.signingKeyID,
            signature: signature.base64EncodedString()
        )
    }

    private func makeMultipartPayload() -> VMOmarchyFactoryManifest.Payload {
        let digest = String(repeating: "a", count: 64)
        return .init(
            schemaVersion: 2,
            imageVersion: "2026.09-multipart",
            imageParts: [
                .init(url: URL(string: "https://download.ezvm.app/factory.part-00")!, byteCount: 10, sha256: digest),
                .init(url: URL(string: "https://download.ezvm.app/factory.part-01")!, byteCount: 20, sha256: digest),
            ],
            imageByteCount: 30,
            imageSHA256: digest,
            architecture: "arm64",
            omarchyRevision: "test-revision",
            guestAgentVersion: "1.0.0",
            guestCapabilities: VMOmarchyProfile.production.factoryGuestCapabilities
        )
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
