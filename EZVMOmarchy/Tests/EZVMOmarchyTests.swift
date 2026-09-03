import XCTest
import EZVMCore
@testable import EZVM_Omarchy

final class EZVMOmarchyTests: XCTestCase {
    func testDedicatedAppUsesOmarchyProductIdentity() throws {
        let profile = VMOmarchyProfile.production
        try profile.validate()
        XCTAssertEqual(profile.productID, "com.everettjf.ezvm.omarchy")
    }

    func testStopRequestsGracefulStopAndWaitsForGuest() {
        var lifecycle = runningLifecycle()

        XCTAssertEqual(lifecycle.handle(.stopRequested), [.requestStop])
        XCTAssertEqual(lifecycle.phase, .stopping)
        XCTAssertFalse(lifecycle.restartAfterStop)
        XCTAssertEqual(lifecycle.handle(.machineStopped), [])
        XCTAssertEqual(lifecycle.phase, .stopped)
    }

    func testRestartStartsNewSessionOnlyAfterGuestStops() {
        var lifecycle = runningLifecycle()

        XCTAssertEqual(lifecycle.handle(.restartRequested), [.requestStop])
        XCTAssertEqual(lifecycle.phase, .stopping)
        XCTAssertTrue(lifecycle.restartAfterStop)
        XCTAssertEqual(lifecycle.handle(.machineStopped), [.startNewSession])
        XCTAssertEqual(lifecycle.phase, .starting)
        XCTAssertFalse(lifecycle.restartAfterStop)
    }

    func testDuplicateLifecycleCommandsAreIgnored() {
        var lifecycle = OmarchyMachineLifecycle()

        XCTAssertEqual(lifecycle.handle(.stopRequested), [])
        XCTAssertEqual(lifecycle.handle(.restartRequested), [])
        XCTAssertEqual(lifecycle.handle(.startRequested), [])
        XCTAssertEqual(lifecycle.phase, .starting)
    }

    func testFailureCancelsPendingRestartAndCanBeRetried() {
        var lifecycle = runningLifecycle()
        _ = lifecycle.handle(.restartRequested)

        XCTAssertEqual(lifecycle.handle(.machineFailed("disk unavailable")), [])
        XCTAssertEqual(lifecycle.phase, .failed("disk unavailable"))
        XCTAssertFalse(lifecycle.restartAfterStop)
        XCTAssertEqual(lifecycle.handle(.startRequested), [.startNewSession])
        XCTAssertEqual(lifecycle.phase, .starting)
    }

    private func runningLifecycle() -> OmarchyMachineLifecycle {
        var lifecycle = OmarchyMachineLifecycle()
        XCTAssertEqual(lifecycle.handle(.machineStarted), [])
        XCTAssertEqual(lifecycle.phase, .running)
        return lifecycle
    }
}
