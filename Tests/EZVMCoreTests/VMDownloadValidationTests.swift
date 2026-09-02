import XCTest
@testable import EZVMCore

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

    func testCapacityOverrideProducesDeterministicErrorIncludingReserve() {
        XCTAssertThrowsError(
            try VMStorageCapacity.validate(
                requiredBytes: 4_096,
                at: FileManager.default.temporaryDirectory,
                reserveBytes: 1_024,
                availableBytesOverride: 5_119
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                VMDownloadValidationError.insufficientDiskSpace(required: 5_120, available: 5_119).localizedDescription
            )
        }
    }

    func testCapacityRequirementOverflowIsClamped() {
        XCTAssertThrowsError(
            try VMStorageCapacity.validate(
                requiredBytes: Int64.max,
                at: FileManager.default.temporaryDirectory,
                reserveBytes: 1,
                availableBytesOverride: Int64.max - 1
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                VMDownloadValidationError.insufficientDiskSpace(
                    required: Int64.max,
                    available: Int64.max - 1
                ).localizedDescription
            )
        }
    }
}
