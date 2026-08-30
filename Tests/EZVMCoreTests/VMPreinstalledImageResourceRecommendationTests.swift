import XCTest
@testable import EZVMCore

#if arch(arm64)
final class VMPreinstalledImageResourceRecommendationTests: XCTestCase {
    private let gibibyte: UInt64 = 1024 * 1024 * 1024

    func testModernMacGetsSixCPUsAndEightGiB() {
        let recommendation = VMPreinstalledImageResourceRecommendation.recommended(
            hostCPUCount: 12,
            hostMemorySize: 24 * gibibyte
        )

        XCTAssertEqual(recommendation.cpuCount, 6)
        XCTAssertEqual(recommendation.memorySize, 8 * gibibyte)
    }

    func testSixteenGiBMacKeepsMoreMemoryForHost() {
        let recommendation = VMPreinstalledImageResourceRecommendation.recommended(
            hostCPUCount: 10,
            hostMemorySize: 16 * gibibyte
        )

        XCTAssertEqual(recommendation.cpuCount, 6)
        XCTAssertEqual(recommendation.memorySize, 6 * gibibyte)
    }

    func testSmallMacScalesCPUAndMemoryDown() {
        let recommendation = VMPreinstalledImageResourceRecommendation.recommended(
            hostCPUCount: 4,
            hostMemorySize: 8 * gibibyte
        )

        XCTAssertEqual(recommendation.cpuCount, 2)
        XCTAssertEqual(recommendation.memorySize, 4 * gibibyte)
    }

    func testFrameworkLimitsAreRespected() {
        let recommendation = VMPreinstalledImageResourceRecommendation.recommended(
            hostCPUCount: 16,
            hostMemorySize: 64 * gibibyte,
            minimumCPUCount: 1,
            maximumCPUCount: 4,
            minimumMemorySize: 2 * gibibyte,
            maximumMemorySize: 7 * gibibyte
        )

        XCTAssertEqual(recommendation.cpuCount, 4)
        XCTAssertEqual(recommendation.memorySize, 7 * gibibyte)
    }
}
#endif
