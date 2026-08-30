import XCTest
@testable import EZVMCore

final class VMGuestAgentEnrollmentTests: XCTestCase {
    func testSharedEnrollmentConfigurationIsPrivateAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "EZVMEnrollmentTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let enrollment = VMGuestAgentEnrollment(
            machineID: "shared-enrollment-test",
            token: Data(repeating: 0x5a, count: 32)
        )

        let result = VMGuestAgentEnrollmentStore.writeSharedConfiguration(
            enrollment,
            directoryURL: root
        )
        guard case let .success(configurationURL) = result else {
            return XCTFail("Could not write shared enrollment: \(result)")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: configurationURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(
            try JSONDecoder().decode(VMGuestAgentEnrollment.self, from: Data(contentsOf: configurationURL)),
            enrollment
        )
    }

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

    func testInstallationConfigurationMustMatchMachineIdentifier() throws {
        let identifier = Data("fixture-machine".utf8)
        let enrollment = VMGuestAgentEnrollment(
            machineID: VMGuestAgentEnrollmentStore.machineID(machineIdentifierData: identifier),
            token: Data(repeating: 7, count: 32)
        )
        let data = try VMGuestAgentEnrollmentStore.installationConfiguration(enrollment)
        XCTAssertEqual(
            try VMGuestAgentEnrollmentStore.decodeInstallationConfiguration(data, machineIdentifierData: identifier),
            enrollment
        )
        XCTAssertThrowsError(try VMGuestAgentEnrollmentStore.decodeInstallationConfiguration(
            data, machineIdentifierData: Data("another-machine".utf8)
        ))
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
