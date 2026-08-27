import Foundation
import XCTest
@testable import EZVMCore

final class VMGuestProvisioningCredentialTests: XCTestCase {
    func testCredentialRoundTripsWithoutChangingFields() throws {
        let credential = VMGuestProvisioningCredential(
            fullName: "Test User",
            username: "testuser",
            password: "correct horse battery staple",
            logsInAutomatically: true,
            enablesRemoteLogin: true
        )

        let encoded = try JSONEncoder().encode(credential)
        let decoded = try JSONDecoder().decode(VMGuestProvisioningCredential.self, from: encoded)

        XCTAssertEqual(decoded, credential)
    }
}
