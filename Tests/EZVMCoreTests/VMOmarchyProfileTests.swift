import XCTest
@testable import EZVMCore

final class VMOmarchyProfileTests: XCTestCase {
    func testProductionProfileIsValidAndRoundTrips() throws {
        let profile = VMOmarchyProfile.production
        try profile.validate()

        let encoded = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(VMOmarchyProfile.self, from: encoded), profile)
        XCTAssertTrue(profile.factoryGuestCapabilities.contains("owner-provisioning-v1"))
        XCTAssertFalse(profile.requiredGuestCapabilities.contains("owner-provisioning-v1"))
    }

    func testResourcePolicyLeavesHalfMemoryAndTwoProcessorsForHost() {
        let gib = UInt64(1_024 * 1_024 * 1_024)
        let constrained = VMOmarchyProfile.production.resources(
            forHostMemory: 12 * gib,
            activeProcessorCount: 4
        )
        XCTAssertEqual(constrained.memoryBytes, 6 * gib)
        XCTAssertEqual(constrained.cpuCount, 2)

        let common = VMOmarchyProfile.production.resources(
            forHostMemory: 32 * gib,
            activeProcessorCount: 10
        )
        XCTAssertEqual(common.memoryBytes, 16 * gib)
        XCTAssertEqual(common.cpuCount, 6)
    }

    func testValidationRejectsUntrustedFactoryManifest() {
        let production = VMOmarchyProfile.production
        let profile = VMOmarchyProfile(
            schemaVersion: production.schemaVersion,
            productID: production.productID,
            minimumHostMajorVersion: production.minimumHostMajorVersion,
            diskCapacityBytes: production.diskCapacityBytes,
            resourceTiers: production.resourceTiers,
            requiredGuestCapabilities: production.requiredGuestCapabilities,
            factoryImage: .init(
                manifestURL: URL(string: "http://example.test/manifest.json")!,
                signingKeyID: "test",
                architecture: "arm64",
                maximumDownloadBytes: 1
            )
        )
        XCTAssertThrowsError(try profile.validate()) { error in
            XCTAssertEqual(error as? VMOmarchyProfile.ValidationError, .invalidFactoryImage)
        }
    }

    func testOwnerProvisioningProgressUsesOnlyKnownPhaseAndSafeLastStep() {
        let progress = VMOmarchyOwnerProvisioningProgress.parse(
            state: Data("finalize\n".utf8),
            log: Data("noise\n[2026-09-03 19:00:00] oem-setup: creating user omarchy\n[2026-09-03 19:00:01] oem-setup: finalizing user\n".utf8)
        )
        XCTAssertEqual(progress.phase, "finalize")
        XCTAssertEqual(progress.lastStep, "finalizing user")
        XCTAssertEqual(progress.displayMessage, "finalizing user")

        let rejected = VMOmarchyOwnerProvisioningProgress.parse(
            state: Data("arbitrary\n".utf8),
            log: Data("[now] oem-setup: unsafe\u{1b}step\n".utf8)
        )
        XCTAssertNil(rejected.phase)
        XCTAssertNil(rejected.lastStep)
        XCTAssertEqual(rejected.displayMessage, "Omarchy is creating your workspace…")
    }
}
