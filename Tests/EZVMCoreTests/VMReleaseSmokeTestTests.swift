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
        XCTAssertFalse(configuration.requireKVM)
        XCTAssertNil(configuration.guestAgentEnrollmentURL)
    }

    func testConfigurationEnablesRealGuestAgentAndKVMGatesExplicitly() throws {
        let configuration = try XCTUnwrap(VMReleaseSmokeTest.configuration(environment: [
            VMReleaseSmokeTest.vmPathEnvironmentKey: "/tmp/smoke.ezvm",
            VMReleaseSmokeTest.resultPathEnvironmentKey: "/tmp/result.txt",
            VMReleaseSmokeTest.requireGuestAgentEnvironmentKey: "1",
            VMReleaseSmokeTest.requireGuestInputEnvironmentKey: "1",
            VMReleaseSmokeTest.requireKVMEnvironmentKey: "1",
            VMReleaseSmokeTest.guestAgentEnrollmentEnvironmentKey: "/tmp/agent.json",
        ]))
        XCTAssertTrue(configuration.requireGuestAgent)
        XCTAssertTrue(configuration.requireGuestInput)
        XCTAssertTrue(configuration.requireKVM)
        XCTAssertEqual(configuration.guestAgentEnrollmentURL?.path, "/tmp/agent.json")
    }
}
#endif
