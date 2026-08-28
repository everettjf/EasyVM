import XCTest
@testable import EZVMCore

final class VMThumbnailValidatorTests: XCTestCase {
    func testRejectsBlackAndNearBlackFrames() {
        XCTAssertFalse(VMThumbnailValidator.isMeaningfulRGBA(Array(repeating: 0, count: 100 * 4)))
        XCTAssertFalse(VMThumbnailValidator.isMeaningfulRGBA(Array(repeating: 18, count: 100 * 4)))
    }

    func testRequiresEnoughVisiblePixelsToRejectIsolatedNoise() {
        var pixels = Array(repeating: UInt8(0), count: 1_000 * 4)
        for pixel in 0..<9 { pixels[pixel * 4] = 255 }
        XCTAssertFalse(VMThumbnailValidator.isMeaningfulRGBA(pixels))
        pixels[9 * 4] = 255
        XCTAssertTrue(VMThumbnailValidator.isMeaningfulRGBA(pixels))
    }

    func testAcceptsAVisibleFrame() {
        var pixels = Array(repeating: UInt8(0), count: 100 * 4)
        pixels[0] = 64
        XCTAssertTrue(VMThumbnailValidator.isMeaningfulRGBA(pixels))
    }
}
