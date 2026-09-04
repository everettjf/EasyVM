import XCTest
@testable import EZVM_Omarchy

final class OmarchyAccessibilityTests: XCTestCase {
    func testAccessibilityButtonTargetsTheAccessibilityPrivacyPane() {
        XCTAssertEqual(
            OmarchyFocusedCommandBridge.accessibilitySettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }
}
