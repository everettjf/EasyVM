import XCTest
@testable import EZVMCore

final class VMOmarchyProfileTests: XCTestCase {
    func testProductionProfileIsValidAndRoundTrips() throws {
        let profile = VMOmarchyProfile.production
        try profile.validate()

        let encoded = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(VMOmarchyProfile.self, from: encoded), profile)
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
}
