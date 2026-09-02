import XCTest
@testable import EZVMCore

#if arch(arm64)
final class VMSystemImageFileValidatorTests: XCTestCase {
    func testAcceptsNonEmptyImageWithExpectedExtensionAndSize() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).iso")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("image".utf8).write(to: url)

        XCTAssertNil(VMSystemImageFileValidator.validate(url, expectedExtension: "iso", expectedSize: 5))
    }

    func testRejectsWrongExtensionEmptyAndWrongSizedImages() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)

        XCTAssertEqual(
            VMSystemImageFileValidator.validate(url, expectedExtension: "iso"),
            "Expected a .iso system image."
        )

        let iso = url.deletingPathExtension().appendingPathExtension("iso")
        defer { try? FileManager.default.removeItem(at: iso) }
        try Data().write(to: iso)
        XCTAssertNotNil(VMSystemImageFileValidator.validate(iso, expectedExtension: "iso"))
        try Data("image".utf8).write(to: iso)
        XCTAssertNotNil(VMSystemImageFileValidator.validate(iso, expectedExtension: "iso", expectedSize: 9))
    }

    func testValidatesExpectedSHA256() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).iso")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("image".utf8).write(to: url)

        XCTAssertNil(VMSystemImageFileValidator.validateSHA256(
            url,
            expectedSHA256: "6105d6cc76af400325e94d588ce511be5bfdbb73b437dc51eca43917d7a43e3d"
        ))
        XCTAssertEqual(
            VMSystemImageFileValidator.validateSHA256(url, expectedSHA256: String(repeating: "0", count: 64)),
            "The system image SHA-256 does not match the vendor catalog."
        )
        XCTAssertEqual(
            VMSystemImageFileValidator.validateSHA256(url, expectedSHA256: "not-a-hash"),
            "The catalog contains an invalid SHA-256 value."
        )
    }
}
#endif
