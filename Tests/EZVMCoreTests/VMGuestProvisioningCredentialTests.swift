import Foundation
import XCTest
@testable import EZVMCore

final class VMGuestProvisioningCredentialTests: XCTestCase {
    func testKeychainAccountIgnoresDirectoryHintAndTrailingSlash() {
        let plain = URL(fileURLWithPath: "/tmp/Provisioned.ezvm")
        let directory = URL(filePath: "/tmp/Provisioned.ezvm/", directoryHint: .isDirectory)
        XCTAssertEqual(
            VMGuestProvisioningCredentialStore.accountKey(vmRootPath: plain),
            VMGuestProvisioningCredentialStore.accountKey(vmRootPath: directory)
        )
        XCTAssertEqual(
            VMGuestProvisioningCredentialStore.accountKey(vmRootPath: directory),
            "/tmp/Provisioned.ezvm"
        )
    }

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

    func testLegacyCredentialDecodesAsPreparedWithAnAttemptIdentifier() throws {
        let legacy = #"{"fullName":"Test User","username":"testuser","password":"secret","logsInAutomatically":false,"enablesRemoteLogin":true}"#

        let credential = try JSONDecoder().decode(
            VMGuestProvisioningCredential.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(credential.attemptState, .prepared)
        XCTAssertFalse(credential.attemptID.uuidString.isEmpty)
    }

    func testAttemptStateTransitionsPreserveIdentityAndSecret() {
        let attemptID = UUID()
        let prepared = VMGuestProvisioningCredential(
            fullName: "Test User",
            username: "testuser",
            password: "secret",
            logsInAutomatically: false,
            enablesRemoteLogin: true,
            attemptID: attemptID
        )

        let applying = prepared.withAttemptState(.applying)
        let awaiting = applying.withAttemptState(.awaitingConfirmation)

        XCTAssertEqual(applying.attemptID, attemptID)
        XCTAssertEqual(awaiting.attemptID, attemptID)
        XCTAssertEqual(awaiting.password, "secret")
        XCTAssertEqual(awaiting.attemptState, .awaitingConfirmation)
    }

    func testOnlyExplicitlyPreparedAttemptIsSubmitted() {
        XCTAssertTrue(VMGuestProvisioningCredentialPolicy.shouldSubmitProvisioning(for: .prepared))
        XCTAssertFalse(VMGuestProvisioningCredentialPolicy.shouldSubmitProvisioning(for: .applying))
        XCTAssertFalse(VMGuestProvisioningCredentialPolicy.shouldSubmitProvisioning(for: .awaitingConfirmation))
    }

    func testCredentialIsRetainedWhenVirtualMachineStarts() {
        XCTAssertFalse(
            VMGuestProvisioningCredentialPolicy.shouldDeleteCredential(
                after: .virtualMachineStarted
            )
        )
    }

    func testCredentialIsDeletedOnlyAfterUserConfirmsSetup() {
        XCTAssertTrue(
            VMGuestProvisioningCredentialPolicy.shouldDeleteCredential(
                after: .userConfirmedSetupCompleted
            )
        )
    }
}
