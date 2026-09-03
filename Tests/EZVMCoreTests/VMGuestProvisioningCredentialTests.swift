import Foundation
import XCTest
import Virtualization
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

    func testProvisioningValidationCodesMapToSpecificFields() {
        XCTAssertEqual(
            VMGuestProvisioningValidationGuidance.classify(domain: VZErrorDomain, code: 40001),
            .invalidFullName
        )
        XCTAssertEqual(
            VMGuestProvisioningValidationGuidance.classify(domain: VZErrorDomain, code: 40002),
            .invalidUsername
        )
        XCTAssertEqual(
            VMGuestProvisioningValidationGuidance.classify(domain: VZErrorDomain, code: 40003),
            .invalidPassword
        )
        XCTAssertEqual(
            VMGuestProvisioningValidationGuidance.classify(domain: "Other", code: 40003),
            .other
        )
    }

    func testProvisioningValidationGuidanceDoesNotEchoSensitiveFrameworkDetails() {
        let secret = "never-echo-this-password"
        let knownError = NSError(
            domain: VZErrorDomain,
            code: 40003,
            userInfo: [NSLocalizedDescriptionKey: "Invalid password: \(secret)"]
        )
        let unknownError = NSError(
            domain: VZErrorDomain,
            code: 49999,
            userInfo: [NSLocalizedDescriptionKey: "Provisioning failed with \(secret)"]
        )

        XCTAssertTrue(VMGuestProvisioningValidationGuidance.message(for: knownError).contains("password"))
        XCTAssertFalse(VMGuestProvisioningValidationGuidance.message(for: knownError).contains(secret))
        XCTAssertFalse(VMGuestProvisioningValidationGuidance.message(for: unknownError).contains(secret))
    }

    func testStartFailureGuidanceExplainsPreparedRetryWithoutFrameworkDetails() {
        let message = VMGuestProvisioningStartFailureGuidance.message(retryWasPrepared: true)

        XCTAssertTrue(message.contains("safe retry"))
        XCTAssertTrue(message.contains("next VM start"))
        XCTAssertFalse(message.contains("localizedDescription"))
    }

    func testStartFailureGuidanceDoesNotPromiseRetryWhenRollbackFails() {
        let message = VMGuestProvisioningStartFailureGuidance.message(retryWasPrepared: false)

        XCTAssertTrue(message.contains("could not prepare a safe retry"))
        XCTAssertTrue(message.contains("review the provisioning status"))
        XCTAssertFalse(message.contains("try again automatically"))
    }
}
