import XCTest
@testable import EZVMCore

#if arch(arm64)
final class VMReleaseSmokeTestTests: XCTestCase {
    func testConfigurationRequiresBothPaths() {
        XCTAssertNil(VMReleaseSmokeTest.configuration(environment: [:]))
        XCTAssertNil(VMReleaseSmokeTest.configuration(environment: [
            VMReleaseSmokeTest.vmPathEnvironmentKey: "/tmp/vm.ezvm"
        ]))
    }

    func testSnapshotConfigurationRequiresValidActionPathsAndID() throws {
        XCTAssertNil(VMReleaseSnapshotTestConfiguration.configuration(environment: [:]))
        XCTAssertNil(VMReleaseSnapshotTestConfiguration.configuration(environment: [
            VMReleaseSnapshotTestConfiguration.actionEnvironmentKey: "unknown",
            VMReleaseSnapshotTestConfiguration.vmPathEnvironmentKey: "/tmp/vm.ezvm",
            VMReleaseSnapshotTestConfiguration.resultPathEnvironmentKey: "/tmp/result"
        ]))
        XCTAssertNil(VMReleaseSnapshotTestConfiguration.configuration(environment: [
            VMReleaseSnapshotTestConfiguration.actionEnvironmentKey: "audit",
            VMReleaseSnapshotTestConfiguration.vmPathEnvironmentKey: "/tmp/vm.ezvm",
            VMReleaseSnapshotTestConfiguration.resultPathEnvironmentKey: "/tmp/result"
        ]))

        let created = try XCTUnwrap(VMReleaseSnapshotTestConfiguration.configuration(environment: [
            VMReleaseSnapshotTestConfiguration.actionEnvironmentKey: "create",
            VMReleaseSnapshotTestConfiguration.vmPathEnvironmentKey: "/tmp/parent/../vm.ezvm",
            VMReleaseSnapshotTestConfiguration.resultPathEnvironmentKey: "/tmp/out/../result"
        ]))
        XCTAssertEqual(created.action, .create)
        XCTAssertEqual(created.vmRootPath.path, "/tmp/vm.ezvm")
        XCTAssertEqual(created.resultPath.path, "/tmp/result")
        XCTAssertNil(created.snapshotID)

        let id = UUID().uuidString
        let restored = try XCTUnwrap(VMReleaseSnapshotTestConfiguration.configuration(environment: [
            VMReleaseSnapshotTestConfiguration.actionEnvironmentKey: "restore",
            VMReleaseSnapshotTestConfiguration.vmPathEnvironmentKey: "/tmp/vm.ezvm",
            VMReleaseSnapshotTestConfiguration.resultPathEnvironmentKey: "/tmp/result",
            VMReleaseSnapshotTestConfiguration.snapshotIDEnvironmentKey: id
        ]))
        XCTAssertEqual(restored.snapshotID, id)
    }

    func testPortabilityConfigurationRequiresOutputExceptForValidation() throws {
        XCTAssertNil(VMReleasePortabilityTestConfiguration.configuration(environment: [:]))
        XCTAssertNil(VMReleasePortabilityTestConfiguration.configuration(environment: [
            VMReleasePortabilityTestConfiguration.actionEnvironmentKey: "export",
            VMReleasePortabilityTestConfiguration.inputEnvironmentKey: "/tmp/source.ezvm",
            VMReleasePortabilityTestConfiguration.resultEnvironmentKey: "/tmp/result"
        ]))

        let validation = try XCTUnwrap(VMReleasePortabilityTestConfiguration.configuration(environment: [
            VMReleasePortabilityTestConfiguration.actionEnvironmentKey: "validate",
            VMReleasePortabilityTestConfiguration.inputEnvironmentKey: "/tmp/a/../machine.ezvmexport",
            VMReleasePortabilityTestConfiguration.resultEnvironmentKey: "/tmp/out/../result"
        ]))
        XCTAssertEqual(validation.action, .validate)
        XCTAssertEqual(validation.inputURL.path, "/tmp/machine.ezvmexport")
        XCTAssertNil(validation.outputURL)
        XCTAssertEqual(validation.resultURL.path, "/tmp/result")

        let importing = try XCTUnwrap(VMReleasePortabilityTestConfiguration.configuration(environment: [
            VMReleasePortabilityTestConfiguration.actionEnvironmentKey: "import",
            VMReleasePortabilityTestConfiguration.inputEnvironmentKey: "/tmp/machine.ezvmexport",
            VMReleasePortabilityTestConfiguration.outputEnvironmentKey: "/tmp/restored.ezvm",
            VMReleasePortabilityTestConfiguration.resultEnvironmentKey: "/tmp/result"
        ]))
        XCTAssertEqual(importing.outputURL?.path, "/tmp/restored.ezvm")
    }

    func testConfigurationStandardizesPaths() throws {
        let configuration = try XCTUnwrap(VMReleaseSmokeTest.configuration(environment: [
            VMReleaseSmokeTest.vmPathEnvironmentKey: "/tmp/parent/../smoke.ezvm",
            VMReleaseSmokeTest.resultPathEnvironmentKey: "/tmp/results/../result.txt",
            VMReleaseSmokeTest.processIDPathEnvironmentKey: "/tmp/pids/../pid.txt",
        ]))

        XCTAssertEqual(configuration.vmRootPath.path, "/tmp/smoke.ezvm")
        XCTAssertEqual(configuration.resultPath.path, "/tmp/result.txt")
        XCTAssertEqual(configuration.processIDPath?.path, "/tmp/pid.txt")
        XCTAssertFalse(configuration.requireGuestAgent)
        XCTAssertFalse(configuration.requireGuestInput)
        XCTAssertFalse(configuration.injectVisibleGuestInput)
        XCTAssertFalse(configuration.requireAbsoluteGuestPointer)
        XCTAssertFalse(configuration.requireKVM)
        XCTAssertFalse(configuration.requireVirGL)
        XCTAssertFalse(configuration.requireMemoryBalloon)
        XCTAssertFalse(configuration.requireEntropy)
        XCTAssertFalse(configuration.requireVirtioSocket)
        XCTAssertFalse(configuration.requireASIFStorage)
        XCTAssertFalse(configuration.requireVMNet)
        XCTAssertFalse(configuration.requireGuestIPv4)
        XCTAssertFalse(configuration.requireMachineStateSupport)
        XCTAssertFalse(configuration.saveMachineState)
        XCTAssertFalse(configuration.forceAppleGraphics)
        XCTAssertEqual(configuration.holdSeconds, 0)
        XCTAssertNil(configuration.holdReadyURL)
        XCTAssertNil(configuration.guestAgentEnrollmentURL)
    }

    func testConfigurationEnablesRealGuestAgentAndKVMGatesExplicitly() throws {
        let configuration = try XCTUnwrap(VMReleaseSmokeTest.configuration(environment: [
            VMReleaseSmokeTest.vmPathEnvironmentKey: "/tmp/smoke.ezvm",
            VMReleaseSmokeTest.resultPathEnvironmentKey: "/tmp/result.txt",
            VMReleaseSmokeTest.requireGuestAgentEnvironmentKey: "1",
            VMReleaseSmokeTest.requireGuestInputEnvironmentKey: "1",
            VMReleaseSmokeTest.injectVisibleGuestInputEnvironmentKey: "1",
            VMReleaseSmokeTest.requireAbsoluteGuestPointerEnvironmentKey: "1",
            VMReleaseSmokeTest.requireKVMEnvironmentKey: "1",
            VMReleaseSmokeTest.requireVirGLEnvironmentKey: "1",
            VMReleaseSmokeTest.requireMemoryBalloonEnvironmentKey: "1",
            VMReleaseSmokeTest.requireEntropyEnvironmentKey: "1",
            VMReleaseSmokeTest.requireVirtioSocketEnvironmentKey: "1",
            VMReleaseSmokeTest.requireASIFStorageEnvironmentKey: "1",
            VMReleaseSmokeTest.requireVMNetEnvironmentKey: "1",
            VMReleaseSmokeTest.requireGuestIPv4EnvironmentKey: "1",
            VMReleaseSmokeTest.requireMachineStateSupportEnvironmentKey: "1",
            VMReleaseSmokeTest.saveMachineStateEnvironmentKey: "1",
            VMReleaseSmokeTest.forceAppleGraphicsEnvironmentKey: "1",
            VMReleaseSmokeTest.holdSecondsEnvironmentKey: "30",
            VMReleaseSmokeTest.holdReadyEnvironmentKey: "/tmp/hold/../ready.txt",
            VMReleaseSmokeTest.guestAgentEnrollmentEnvironmentKey: "/tmp/agent.json",
        ]))
        XCTAssertTrue(configuration.requireGuestAgent)
        XCTAssertTrue(configuration.requireGuestInput)
        XCTAssertTrue(configuration.injectVisibleGuestInput)
        XCTAssertTrue(configuration.requireAbsoluteGuestPointer)
        XCTAssertTrue(configuration.requireKVM)
        XCTAssertTrue(configuration.requireVirGL)
        XCTAssertTrue(configuration.requireMemoryBalloon)
        XCTAssertTrue(configuration.requireEntropy)
        XCTAssertTrue(configuration.requireVirtioSocket)
        XCTAssertTrue(configuration.requireASIFStorage)
        XCTAssertTrue(configuration.requireVMNet)
        XCTAssertTrue(configuration.requireGuestIPv4)
        XCTAssertTrue(configuration.requireMachineStateSupport)
        XCTAssertTrue(configuration.saveMachineState)
        XCTAssertTrue(configuration.forceAppleGraphics)
        XCTAssertEqual(configuration.holdSeconds, 30)
        XCTAssertEqual(configuration.holdReadyURL?.path, "/tmp/ready.txt")
        XCTAssertEqual(configuration.guestAgentEnrollmentURL?.path, "/tmp/agent.json")
    }

    func testConfigurationRejectsOutOfRangePerformanceHold() throws {
        let configuration = try XCTUnwrap(VMReleaseSmokeTest.configuration(environment: [
            VMReleaseSmokeTest.vmPathEnvironmentKey: "/tmp/smoke.ezvm",
            VMReleaseSmokeTest.resultPathEnvironmentKey: "/tmp/result.txt",
            VMReleaseSmokeTest.holdSecondsEnvironmentKey: "601",
        ]))
        XCTAssertEqual(configuration.holdSeconds, 0)
    }
}
#endif
