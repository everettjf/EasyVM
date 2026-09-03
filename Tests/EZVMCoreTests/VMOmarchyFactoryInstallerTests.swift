import CryptoKit
import XCTest
@testable import EZVMCore

final class VMOmarchyFactoryInstallerTests: XCTestCase {
    func testInstallerVerifiesBeforeDownloadingAndPublishesAtomically() async throws {
        let fixture = try Fixture()
        let transport = MockTransport(manifestData: fixture.manifestData, image: fixture.image)
        let installer = VMOmarchyFactoryInstaller(
            profile: fixture.profile,
            cacheDirectory: fixture.cache,
            publicKey: fixture.key.publicKey.rawRepresentation,
            transport: transport
        )
        let installed = try await installer.install()
        XCTAssertEqual(try Data(contentsOf: installed.diskURL), fixture.image)
        XCTAssertEqual(installed.manifest.payload.imageVersion, "test")
        XCTAssertEqual(installed.manifest.payload.omarchyRevision, "revision")
        XCTAssertEqual(installed.manifest.payload.guestAgentVersion, "1")
        XCTAssertEqual(transport.downloadCount, 1)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path)
            .contains(where: { $0.hasPrefix(".Factory-") }))

        let reused = try await installer.install()
        XCTAssertEqual(reused, installed)
        XCTAssertEqual(transport.downloadCount, 1)
    }

    func testInvalidManifestNeverStartsImageDownload() async throws {
        let fixture = try Fixture(tamperSignature: true)
        let transport = MockTransport(manifestData: fixture.manifestData, image: fixture.image)
        let installer = VMOmarchyFactoryInstaller(
            profile: fixture.profile,
            cacheDirectory: fixture.cache,
            publicKey: fixture.key.publicKey.rawRepresentation,
            transport: transport
        )
        do {
            _ = try await installer.install()
            XCTFail("Expected signature failure")
        } catch {
            XCTAssertEqual(error as? VMOmarchyFactoryValidationError, .invalidSignature)
        }
        XCTAssertEqual(transport.downloadCount, 0)
    }

    func testReleaseCheckVerifiesManifestWithoutDownloadingImage() async throws {
        let fixture = try Fixture()
        let transport = MockTransport(manifestData: fixture.manifestData, image: fixture.image)
        let installer = VMOmarchyFactoryInstaller(
            profile: fixture.profile,
            cacheDirectory: fixture.cache,
            publicKey: fixture.key.publicKey.rawRepresentation,
            transport: transport
        )

        let manifest = try await installer.fetchVerifiedManifest()

        XCTAssertEqual(manifest.payload.imageVersion, "test")
        XCTAssertEqual(transport.downloadCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.path))
        XCTAssertEqual(
            VMOmarchyFactoryChannelState.assess(installedVersion: "test", manifest: manifest),
            .current(version: "test")
        )
        XCTAssertEqual(
            VMOmarchyFactoryChannelState.assess(installedVersion: "old", manifest: manifest),
            .different(installedVersion: "old", availableVersion: "test")
        )
        XCTAssertEqual(
            VMOmarchyFactoryChannelState.assess(installedVersion: nil, manifest: manifest),
            .untracked(availableVersion: "test")
        )
    }

    func testReleaseCheckRejectsTamperedManifestWithoutCreatingCache() async throws {
        let fixture = try Fixture(tamperSignature: true)
        let transport = MockTransport(manifestData: fixture.manifestData, image: fixture.image)
        let installer = VMOmarchyFactoryInstaller(
            profile: fixture.profile,
            cacheDirectory: fixture.cache,
            publicKey: fixture.key.publicKey.rawRepresentation,
            transport: transport
        )

        await XCTAssertThrowsErrorAsync(try await installer.fetchVerifiedManifest()) { error in
            XCTAssertEqual(error as? VMOmarchyFactoryValidationError, .invalidSignature)
        }
        XCTAssertEqual(transport.downloadCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.path))
    }

    func testReleaseCheckRejectsOversizedManifestBeforeDecodingOrDownloading() async throws {
        let fixture = try Fixture()
        let transport = MockTransport(
            manifestData: Data(repeating: 0x7b, count: VMOmarchyFactoryInstaller.maximumManifestBytes + 1),
            image: fixture.image
        )
        let installer = VMOmarchyFactoryInstaller(
            profile: fixture.profile,
            cacheDirectory: fixture.cache,
            publicKey: fixture.key.publicKey.rawRepresentation,
            transport: transport
        )

        await XCTAssertThrowsErrorAsync(try await installer.fetchVerifiedManifest()) { error in
            XCTAssertEqual(error as? VMOmarchyFactoryInstallError, .manifestTooLarge)
        }
        XCTAssertEqual(transport.downloadCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.path))
    }

    private final class MockTransport: VMOmarchyFactoryTransport {
        let manifestData: Data
        let image: Data
        var downloadCount = 0

        init(manifestData: Data, image: Data) {
            self.manifestData = manifestData
            self.image = image
        }

        func fetchData(from url: URL) async throws -> Data { manifestData }

        func downloadFile(
            from url: URL,
            to destination: URL,
            resumeDataURL: URL,
            progress: @escaping (Int64, Int64) -> Void
        ) async throws {
            downloadCount += 1
            try image.write(to: destination)
            progress(Int64(image.count), Int64(image.count))
        }
    }

    private struct Fixture {
        let root: URL
        let cache: URL
        let key: Curve25519.Signing.PrivateKey
        let image: Data
        let profile: VMOmarchyProfile
        let manifestData: Data

        init(tamperSignature: Bool = false) throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "OmarchyInstallerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            cache = root.appending(path: "cache")
            key = Curve25519.Signing.PrivateKey()
            image = Data("factory-image".utf8)
            let digest = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
            let signingKeyID = "test-key"
            profile = VMOmarchyProfile(
                schemaVersion: 1,
                productID: "com.everettjf.ezvm.omarchy",
                minimumHostMajorVersion: 27,
                diskCapacityBytes: 64 * 1_024 * 1_024 * 1_024,
                resourceTiers: VMOmarchyProfile.production.resourceTiers,
                requiredGuestCapabilities: ["desktop-input-v1"],
                factoryImage: .init(
                    manifestURL: URL(string: "https://example.test/manifest.json")!,
                    signingKeyID: signingKeyID,
                    architecture: "arm64",
                    maximumDownloadBytes: 1_024
                )
            )
            let payload = VMOmarchyFactoryManifest.Payload(
                schemaVersion: 1,
                imageVersion: "test",
                imageURL: URL(string: "https://example.test/factory.asif")!,
                imageByteCount: UInt64(image.count),
                imageSHA256: digest,
                architecture: "arm64",
                omarchyRevision: "revision",
                guestAgentVersion: "1",
                guestCapabilities: VMOmarchyProfile.production.requiredGuestCapabilities.sorted()
            )
            var signature = try key.signature(for: VMOmarchyFactoryValidator.canonicalPayload(payload))
            if tamperSignature { signature[0] ^= 0xff }
            manifestData = try JSONEncoder().encode(VMOmarchyFactoryManifest(
                payload: payload,
                keyID: signingKeyID,
                signature: signature.base64EncodedString()
            ))
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
