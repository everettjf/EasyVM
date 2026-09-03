import XCTest
@testable import EZVMCore

final class VMOmarchyConnectionSuspensionGateTests: XCTestCase {
    func testNestedSleepAndPauseRequireBothReasonsToResume() {
        var gate = VMOmarchyConnectionSuspensionGate()

        gate.suspend(for: .hostSleeping)
        gate.suspend(for: .virtualMachinePaused)
        XCTAssertTrue(gate.isSuspended)
        XCTAssertFalse(gate.resume(after: .hostSleeping))
        XCTAssertTrue(gate.isSuspended)
        XCTAssertTrue(gate.resume(after: .virtualMachinePaused))
        XCTAssertFalse(gate.isSuspended)
    }

    func testDuplicateAndUnknownResumeNeverTriggerReconnect() {
        var gate = VMOmarchyConnectionSuspensionGate()

        gate.suspend(for: .hostSleeping)
        gate.suspend(for: .hostSleeping)
        XCTAssertFalse(gate.resume(after: .virtualMachinePaused))
        XCTAssertTrue(gate.isSuspended)
        XCTAssertTrue(gate.resume(after: .hostSleeping))
        XCTAssertFalse(gate.resume(after: .hostSleeping))
    }

    func testResetClearsEverySuspensionReason() {
        var gate = VMOmarchyConnectionSuspensionGate()
        gate.suspend(for: .hostSleeping)
        gate.suspend(for: .virtualMachinePaused)

        gate.reset()

        XCTAssertFalse(gate.isSuspended)
    }
}
