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
}
#endif
