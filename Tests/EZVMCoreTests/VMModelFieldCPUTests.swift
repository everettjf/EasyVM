import XCTest
@testable import EZVMCore

#if arch(arm64)
final class VMCPUResourceRecommendationTests: XCTestCase {
    func testRecommendationLeavesTwoHostCPUsAndCapsAtSix() {
        XCTAssertEqual(recommended(host: 11), 6)
        XCTAssertEqual(recommended(host: 8), 6)
        XCTAssertEqual(recommended(host: 4), 2)
        XCTAssertEqual(recommended(host: 2), 1)
        XCTAssertEqual(recommended(host: 1), 1)
    }

    func testRecommendationRespectsFrameworkLimits() {
        XCTAssertEqual(
            VMCPUResourceRecommendation.recommended(
                hostCPUCount: 16,
                minimumCPUCount: 2,
                maximumCPUCount: 4
            ),
            4
        )
        XCTAssertEqual(
            VMCPUResourceRecommendation.recommended(
                hostCPUCount: 2,
                minimumCPUCount: 2,
                maximumCPUCount: 8
            ),
            2
        )
    }

    private func recommended(host: Int) -> Int {
        VMCPUResourceRecommendation.recommended(
            hostCPUCount: host,
            minimumCPUCount: 1,
            maximumCPUCount: 64
        )
    }
}
#endif
