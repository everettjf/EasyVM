import XCTest
@testable import EasyVMCore

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
            VMReleaseSmokeTest.resultPathEnvironmentKey: "/tmp/results/../result.txt"
        ]))

        XCTAssertEqual(configuration.vmRootPath.path, "/tmp/smoke.ezvm")
        XCTAssertEqual(configuration.resultPath.path, "/tmp/result.txt")
        XCTAssertFalse(configuration.requireGuestAgent)
        XCTAssertFalse(configuration.requireKVM)
    }

    func testConfigurationEnablesRealGuestAgentAndKVMGatesExplicitly() throws {
        let configuration = try XCTUnwrap(VMReleaseSmokeTest.configuration(environment: [
            VMReleaseSmokeTest.vmPathEnvironmentKey: "/tmp/smoke.ezvm",
            VMReleaseSmokeTest.resultPathEnvironmentKey: "/tmp/result.txt",
            VMReleaseSmokeTest.requireGuestAgentEnvironmentKey: "1",
            VMReleaseSmokeTest.requireKVMEnvironmentKey: "1",
        ]))
        XCTAssertTrue(configuration.requireGuestAgent)
        XCTAssertTrue(configuration.requireKVM)
    }
}
#endif
