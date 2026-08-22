import XCTest
@testable import EasyVMCore

final class VMGuestAgentEnrollmentTests: XCTestCase {
    func testMachineIdentityIsStableAndSensitiveToIdentifier() {
        let first = VMGuestAgentEnrollmentStore.machineID(machineIdentifierData: Data("machine-a".utf8))
        let again = VMGuestAgentEnrollmentStore.machineID(machineIdentifierData: Data("machine-a".utf8))
        let second = VMGuestAgentEnrollmentStore.machineID(machineIdentifierData: Data("machine-b".utf8))
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.count, 64)
    }

    func testInstallationConfigurationRoundTripsWithoutPlaintextJSONKeyNamesChanging() throws {
        let enrollment = VMGuestAgentEnrollment(machineID: "machine-a", token: Data(repeating: 9, count: 32))
        let data = try VMGuestAgentEnrollmentStore.installationConfiguration(enrollment)
        let decoded = try JSONDecoder().decode(VMGuestAgentEnrollment.self, from: data)
        XCTAssertEqual(decoded, enrollment)
        try decoded.validate()
    }

    func testEnrollmentRejectsWrongTokenLengthSchemaAndPort() throws {
        let invalidToken = VMGuestAgentEnrollment(machineID: "machine-a", token: Data())
        XCTAssertThrowsError(try invalidToken.validate())

        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 99,
            "machineID": "machine-a",
            "token": Data(repeating: 1, count: 32).base64EncodedString(),
            "port": 9999,
        ])
        let decoded = try JSONDecoder().decode(VMGuestAgentEnrollment.self, from: data)
        XCTAssertThrowsError(try decoded.validate())
    }

    func testGeneratedTokensHaveExpectedLengthAndAreUnique() {
        let first = VMGuestAgentAuthenticator.generateToken()
        let second = VMGuestAgentAuthenticator.generateToken()
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(second.count, 32)
        XCTAssertNotEqual(first, second)
    }
}
