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
        XCTAssertEqual(configuration.guestAgentEnrollmentURL?.path, "/tmp/agent.json")
    }
}
#endif
