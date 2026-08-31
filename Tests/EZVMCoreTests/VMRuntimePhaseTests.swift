import XCTest
@testable import EZVMCore

final class VMRuntimePhaseTests: XCTestCase {
    func testOnlyStoppedPhaseDismissesMachineWindow() {
        let activePhases: [VMRuntimePhase] = [
            .preparing, .starting, .restoring, .running, .pausing,
            .paused, .saving, .stopping, .failed("example")
        ]

        XCTAssertTrue(VMRuntimePhase.stopped.shouldDismissMachineWindow)
        XCTAssertTrue(activePhases.allSatisfy { !$0.shouldDismissMachineWindow })
    }

    func testStoppingPhaseRemainsDistinctFromStoppedForForceStopFallback() {
        XCTAssertFalse(VMRuntimePhase.stopping.shouldDismissMachineWindow)
        XCTAssertTrue(VMRuntimePhase.stopped.shouldDismissMachineWindow)
    }

    func testMachineStateSavingRequiresBothAnActivePhaseAndBackendSupport() {
        XCTAssertTrue(VMRuntimePhase.running.canSaveMachineState(backendSupportsSaveRestore: true))
        XCTAssertTrue(VMRuntimePhase.paused.canSaveMachineState(backendSupportsSaveRestore: true))
        XCTAssertFalse(VMRuntimePhase.running.canSaveMachineState(backendSupportsSaveRestore: false))
        XCTAssertFalse(VMRuntimePhase.stopping.canSaveMachineState(backendSupportsSaveRestore: true))
    }
}
