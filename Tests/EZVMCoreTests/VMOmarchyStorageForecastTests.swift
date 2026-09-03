import XCTest
@testable import EZVMCore

final class VMOmarchyStorageForecastTests: XCTestCase {
    func testForecastIncludesDownloadWorkspaceAndSafetyReserve() {
        let forecast = VMOmarchyStorageForecast(
            downloadBytes: 10,
            workspaceBytes: 100,
            reserveBytes: 20,
            availableBytes: 130
        )
        XCTAssertEqual(forecast.requiredBytes, 130)
        XCTAssertTrue(forecast.hasEnoughSpace)
        XCTAssertFalse(VMOmarchyStorageForecast(
            downloadBytes: 10,
            workspaceBytes: 100,
            reserveBytes: 20,
            availableBytes: 129
        ).hasEnoughSpace)
    }

    func testForecastClampsOverflowInsteadOfWrapping() {
        let forecast = VMOmarchyStorageForecast(
            downloadBytes: .max,
            workspaceBytes: 1,
            reserveBytes: 1,
            availableBytes: .max
        )
        XCTAssertEqual(forecast.requiredBytes, .max)
        XCTAssertTrue(forecast.hasEnoughSpace)
    }
}
