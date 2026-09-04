import XCTest
@testable import EZVM_Omarchy

final class OmarchyAccessibilityTests: XCTestCase {
    func testAccessibilityButtonTargetsTheAccessibilityPrivacyPane() {
        XCTAssertEqual(
            OmarchyFocusedCommandBridge.accessibilitySettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    func testHostAcceptanceTextEncoderCoversPrintableCredentialCharacters() throws {
        let strokes = try XCTUnwrap(
            OmarchyHostKeyboardTextEncoder.strokes(for: "aZ09-_!@ /?\n")
        )
        XCTAssertEqual(strokes.count, 12)
        XCTAssertEqual(strokes[0], .init(keyCode: 0, shifted: false))
        XCTAssertEqual(strokes[1], .init(keyCode: 6, shifted: true))
        XCTAssertEqual(strokes[2], .init(keyCode: 29, shifted: false))
        XCTAssertEqual(strokes[3], .init(keyCode: 25, shifted: false))
        XCTAssertEqual(strokes.last, .init(keyCode: 36, shifted: false))

        let printableASCII = String(
            (0x20...0x7e).map { Character(UnicodeScalar($0)!) }
        )
        XCTAssertEqual(
            OmarchyHostKeyboardTextEncoder.strokes(for: printableASCII)?.count,
            95
        )
        XCTAssertEqual(
            OmarchyHostKeyboardTextEncoder.deliveryDuration(for: "123456\n"),
            .milliseconds(600)
        )
    }

    func testHostAcceptanceTextEncoderRejectsNonASCII() {
        XCTAssertNil(OmarchyHostKeyboardTextEncoder.strokes(for: "密碼"))
    }
}
