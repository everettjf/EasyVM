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

    func testKeychainAccountFollowsStableMachineIdentityWhenBundleMoves() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let original = root.appendingPathComponent("Original.ezvm", isDirectory: true)
        let moved = root.appendingPathComponent("Moved.ezvm", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let identifier = Data("stable-machine-identity".utf8)
        try identifier.write(to: original.appendingPathComponent("MachineIdentifier"))
        defer { try? FileManager.default.removeItem(at: root) }

        let originalKey = VMGuestProvisioningCredentialStore.accountKey(vmRootPath: original)
        try FileManager.default.moveItem(at: original, to: moved)
        let movedKey = VMGuestProvisioningCredentialStore.accountKey(vmRootPath: moved)

        XCTAssertEqual(originalKey, movedKey)
        XCTAssertEqual(
            originalKey,
            "machine:\(VMGuestAgentEnrollmentStore.machineID(machineIdentifierData: identifier))"
        )
    }

    func testKeychainAccountSeparatesClonesWithNewMachineIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = root.appendingPathComponent("First.ezvm", isDirectory: true)
        let second = root.appendingPathComponent("Second.ezvm", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: first.appendingPathComponent("MachineIdentifier"))
        try Data("second".utf8).write(to: second.appendingPathComponent("MachineIdentifier"))
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNotEqual(
            VMGuestProvisioningCredentialStore.accountKey(vmRootPath: first),
            VMGuestProvisioningCredentialStore.accountKey(vmRootPath: second)
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
        XCTAssertTrue(
            VMGuestProvisioningCredentialPolicy.shouldDeleteCredential(
                after: .userChoseManualSetup
            )
        )
    }

    func testCreationCredentialTransactionPreparesBeforeInstallAndRollsBackFailure() {
        let root = URL(fileURLWithPath: "/tmp/Provisioning-Transaction.ezvm")
        let credential = VMGuestProvisioningCredential(
            fullName: "Test User",
            username: "testuser",
            password: "secret",
            logsInAutomatically: false,
            enablesRemoteLogin: true
        )
        var events: [String] = []
        var transaction = VMGuestProvisioningCreationCredentialTransaction(vmRootPath: root)

        assertSuccess(transaction.prepare(credential) { saved, url in
            events.append("save")
            XCTAssertEqual(saved, credential)
            XCTAssertEqual(url, root)
            return .success
        })
        XCTAssertTrue(transaction.isPrepared)
        events.append("install")
        assertSuccess(transaction.rollback { url in
            events.append("delete")
            XCTAssertEqual(url, root)
            return .success
        })
        XCTAssertEqual(events, ["save", "install", "delete"])
        XCTAssertFalse(transaction.isPrepared)
    }

    func testCreationCredentialTransactionCommitTransfersCleanupToVMLifecycle() {
        let root = URL(fileURLWithPath: "/tmp/Provisioning-Commit.ezvm")
        let credential = VMGuestProvisioningCredential(
            fullName: "Test User", username: "testuser", password: "secret",
            logsInAutomatically: true, enablesRemoteLogin: true
        )
        var deleteCalled = false
        var transaction = VMGuestProvisioningCreationCredentialTransaction(vmRootPath: root)

        assertSuccess(transaction.prepare(credential) { _, _ in .success })
        transaction.commit()
        assertSuccess(transaction.rollback { _ in
            deleteCalled = true
            return .success
        })
        XCTAssertFalse(deleteCalled)
    }

    func testCreationCredentialTransactionRetainsCleanupResponsibilityAfterDeleteFailure() {
        let root = URL(fileURLWithPath: "/tmp/Provisioning-Cleanup.ezvm")
        let credential = VMGuestProvisioningCredential(
            fullName: "Test User", username: "testuser", password: "secret",
            logsInAutomatically: false, enablesRemoteLogin: false
        )
        var transaction = VMGuestProvisioningCreationCredentialTransaction(vmRootPath: root)

        assertSuccess(transaction.prepare(credential) { _, _ in .success })
        guard case .failure = transaction.rollback(delete: { _ in .failure("Keychain unavailable") }) else {
            return XCTFail("Expected cleanup failure")
        }
        XCTAssertTrue(transaction.isPrepared)
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

    func testRetryRecoveryRestoresPreparedStateWithoutChangingAttemptOrSecret() {
        let root = URL(fileURLWithPath: "/tmp/Provisioning-Retry.ezvm")
        let attemptID = UUID()
        let applying = VMGuestProvisioningCredential(
            fullName: "Test User",
            username: "testuser",
            password: "secret",
            logsInAutomatically: true,
            enablesRemoteLogin: true,
            attemptID: attemptID,
            attemptState: .applying
        )
        var savedCredential: VMGuestProvisioningCredential?

        assertSuccess(VMGuestProvisioningRetryRecovery.prepare(
            credential: applying,
            vmRootPath: root
        ) { credential, url in
            savedCredential = credential
            XCTAssertEqual(url, root)
            return .success
        })

        XCTAssertEqual(savedCredential?.attemptState, .prepared)
        XCTAssertEqual(savedCredential?.attemptID, attemptID)
        XCTAssertEqual(savedCredential?.password, "secret")
    }

    func testRetryRecoveryReportsKeychainFailureInsteadOfClaimingPreparedState() {
        let credential = VMGuestProvisioningCredential(
            fullName: "Test User",
            username: "testuser",
            password: "secret",
            logsInAutomatically: false,
            enablesRemoteLogin: false,
            attemptState: .applying
        )

        guard case let .failure(message) = VMGuestProvisioningRetryRecovery.prepare(
            credential: credential,
            vmRootPath: URL(fileURLWithPath: "/tmp/Provisioning-Retry-Failure.ezvm"),
            save: { _, _ in .failure("Keychain unavailable") }
        ) else {
            return XCTFail("Expected retry recovery failure")
        }

        XCTAssertEqual(message, "Keychain unavailable")
    }

    func testProvisioningRequiresMacOS27OrLaterGuest() {
        XCTAssertFalse(VMGuestProvisioningCompatibility.supportsGuest(version: "26.6.2"))
        XCTAssertTrue(VMGuestProvisioningCompatibility.supportsGuest(version: "27.0"))
        XCTAssertTrue(VMGuestProvisioningCompatibility.supportsGuest(version: "28.1.3"))
        XCTAssertFalse(VMGuestProvisioningCompatibility.supportsGuest(version: "unknown"))
    }

    func testUnsupportedGuestGuidanceNamesDetectedVersionAndRequiredVersion() {
        let message = VMGuestProvisioningCompatibility.unsupportedGuestMessage(version: "26.6.2")

        XCTAssertTrue(message.contains("macOS 27 or later guest"))
        XCTAssertTrue(message.contains("macOS 26.6.2"))
        XCTAssertTrue(message.contains("IPSW"))
    }

    private func assertSuccess(
        _ result: VMOSResultVoid,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case let .failure(message) = result {
            XCTFail("Expected success, got: \(message)", file: file, line: line)
        }
    }
}
