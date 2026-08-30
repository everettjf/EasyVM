import Foundation
import Virtualization
import XCTest
@testable import EZVMCore

final class VMLinuxFeatureConfigurationTests: XCTestCase {
    func testCustomVirGLPreferenceDefaultsOnAndRespectsExplicitOptOut() throws {
        let suiteName = "VMLinuxFeatureConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(EZVMExperimentalFeatures.customVirGLGraphicsEnabled(defaults: defaults))
        defaults.set(false, forKey: EZVMExperimentalFeatures.customVirGLGraphicsKey)
        XCTAssertFalse(EZVMExperimentalFeatures.customVirGLGraphicsEnabled(defaults: defaults))
    }

    func testCustomVirGLNeverActivatesForMacOSGuests() {
        let selection = VMGraphicsBackendSelection.resolve(
            isLinux: false,
            hostSupportsCustomVirtio: true,
            experimentalEnabled: true,
            customBackendImplemented: true
        )
        XCTAssertEqual(selection.requested, .appleVirtio)
        XCTAssertEqual(selection.active, .appleVirtio)
        XCTAssertNil(selection.fallbackReason)
    }

    func testCustomVirGLSelectionDefaultsToAppleBackend() {
        let selection = VMGraphicsBackendSelection.resolve(
            isLinux: true,
            hostSupportsCustomVirtio: true,
            experimentalEnabled: false,
            customBackendImplemented: true
        )
        XCTAssertEqual(selection.active, .appleVirtio)
        XCTAssertNil(selection.fallbackReason)
    }

    func testCustomVirGLSelectionFallsBackUntilRuntimeIsLinked() {
        let selection = VMGraphicsBackendSelection.resolve(
            isLinux: true,
            hostSupportsCustomVirtio: true,
            experimentalEnabled: true,
            customBackendImplemented: false
        )
        XCTAssertEqual(selection.requested, .customVirGL)
        XCTAssertEqual(selection.active, .appleVirtio)
        XCTAssertNotNil(selection.fallbackReason)
    }

    func testCustomVirGLSelectionActivatesOnlyWhenAllGatesPass() {
        let selection = VMGraphicsBackendSelection.resolve(
            isLinux: true,
            hostSupportsCustomVirtio: true,
            experimentalEnabled: true,
            customBackendImplemented: true
        )
        XCTAssertEqual(selection.active, .customVirGL)
        XCTAssertNil(selection.fallbackReason)
    }
    func testRecommendedFeaturesRoundTripAndCreateVirtioDevices() throws {
        let encoded = try JSONEncoder().encode(VMLinuxFeatureConfiguration.recommended)
        let decoded = try JSONDecoder().decode(VMLinuxFeatureConfiguration.self, from: encoded)
        XCTAssertEqual(decoded, .recommended)

        let configuration = VZVirtualMachineConfiguration()
        guard case .success = decoded.applyDevices(to: configuration, existingDirectoryTags: []) else {
            return XCTFail("Recommended Linux devices should be configurable")
        }
        XCTAssertEqual(configuration.memoryBalloonDevices.count, 1)
        XCTAssertEqual(configuration.entropyDevices.count, 1)
        XCTAssertEqual(configuration.socketDevices.count, 1)
        XCTAssertTrue(configuration.directorySharingDevices.isEmpty)
    }

    func testLegacyFeaturesDoNotChangeVirtualHardware() {
        let configuration = VZVirtualMachineConfiguration()
        guard case .success = VMLinuxFeatureConfiguration.legacy.applyDevices(to: configuration, existingDirectoryTags: []) else {
            return XCTFail("Legacy Linux configuration should remain valid")
        }
        XCTAssertTrue(configuration.memoryBalloonDevices.isEmpty)
        XCTAssertTrue(configuration.entropyDevices.isEmpty)
        XCTAssertTrue(configuration.socketDevices.isEmpty)
        XCTAssertTrue(configuration.directorySharingDevices.isEmpty)
    }

    func testOlderFeatureJSONDefaultsNestedVirtualizationOff() throws {
        let data = Data(#"{"rosettaEnabled":false,"memoryBalloonEnabled":true,"entropyEnabled":true,"virtioSocketEnabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(VMLinuxFeatureConfiguration.self, from: data)
        XCTAssertFalse(decoded.nestedVirtualizationEnabled)
        XCTAssertTrue(decoded.memoryBalloonEnabled)
    }

    func testNestedVirtualizationRejectsUnsupportedHostWithActionableError() {
        var features = VMLinuxFeatureConfiguration.legacy
        features.nestedVirtualizationEnabled = true
        let platform = VZGenericPlatformConfiguration()
        guard case let .failure(error) = features.applyPlatform(to: platform, isSupported: false) else {
            return XCTFail("Unsupported hosts must reject nested virtualization")
        }
        XCTAssertTrue(error.contains("M3"))
        XCTAssertFalse(platform.isNestedVirtualizationEnabled)
    }

    func testNestedVirtualizationEnablesPlatformWhenSupported() {
        var features = VMLinuxFeatureConfiguration.legacy
        features.nestedVirtualizationEnabled = true
        let platform = VZGenericPlatformConfiguration()
        guard case .success = features.applyPlatform(to: platform, isSupported: true) else {
            return XCTFail("Supported hosts should enable nested virtualization")
        }
        XCTAssertTrue(platform.isNestedVirtualizationEnabled)
    }

    func testRosettaShareHonorsAvailabilityAndReservedTag() {
        var features = VMLinuxFeatureConfiguration.legacy
        features.rosettaEnabled = true
        features.rosettaCachingEnabled = true

        let conflicting = VZVirtualMachineConfiguration()
        guard case .failure = features.applyDevices(to: conflicting, existingDirectoryTags: ["rosetta"]) else {
            return XCTFail("The Rosetta tag must be reserved")
        }

        let configuration = VZVirtualMachineConfiguration()
        switch VZLinuxRosettaDirectoryShare.availability {
        case .installed:
            guard case .success = features.applyDevices(to: configuration, existingDirectoryTags: []) else {
                return XCTFail("Installed Rosetta should create a directory-sharing device")
            }
            XCTAssertEqual(configuration.directorySharingDevices.count, 1)
        case .notInstalled, .notSupported:
            guard case .failure = features.applyDevices(to: configuration, existingDirectoryTags: []) else {
                return XCTFail("Unavailable Rosetta must produce an actionable failure")
            }
        @unknown default:
            break
        }
    }

    func testSecureBootCanBeEnabledAndDisabledInTemporaryVariableStore() throws {
        guard #available(macOS 27.0, *) else { return }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try VZEFIVariableStore(creatingVariableStoreAt: directory.appending(path: "NVRAM"))
        guard case .success = VMEFISecureBootManager.apply(enabled: true, variableStore: store) else {
            return XCTFail("Expected default Secure Boot enrollment to succeed")
        }
        XCTAssertTrue(try store.isSecureBootEnabled)

        guard case .success = VMEFISecureBootManager.apply(enabled: false, variableStore: store) else {
            return XCTFail("Expected Secure Boot disable to succeed")
        }
        XCTAssertFalse(try store.isSecureBootEnabled)
    }
}
