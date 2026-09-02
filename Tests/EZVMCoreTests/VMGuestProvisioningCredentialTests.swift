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
