import XCTest
@testable import EasyVMCore

final class VMDownloadValidationTests: XCTestCase {
    func testValidationErrorsExplainCorruptDownloads() {
        XCTAssertNotNil(VMDownloadValidationError.emptyFile.errorDescription)
        XCTAssertEqual(
            VMDownloadValidationError.sizeMismatch(expected: 100, actual: 10).errorDescription,
            "Expected 100 bytes but downloaded 10 bytes."
        )
    }

    func testTinyRequirementFitsTemporaryVolume() throws {
        try VMStorageCapacity.validate(requiredBytes: 1, at: FileManager.default.temporaryDirectory, reserveBytes: 0)
    }
}
