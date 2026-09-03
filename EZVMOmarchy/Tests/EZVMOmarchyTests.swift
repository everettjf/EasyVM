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

        XCTAssertEqual(lifecycle.handle(.stopRequested), [.requestStop, .scheduleForceStop])
        XCTAssertEqual(lifecycle.phase, .stopping)
        XCTAssertFalse(lifecycle.restartAfterStop)
        XCTAssertEqual(lifecycle.handle(.machineStopped), [.cancelForceStop])
        XCTAssertEqual(lifecycle.phase, .stopped)
    }

    func testRestartStartsNewSessionOnlyAfterGuestStops() {
        var lifecycle = runningLifecycle()

        XCTAssertEqual(lifecycle.handle(.restartRequested), [.requestStop, .scheduleForceStop])
        XCTAssertEqual(lifecycle.phase, .stopping)
        XCTAssertTrue(lifecycle.restartAfterStop)
        XCTAssertEqual(lifecycle.handle(.machineStopped), [.cancelForceStop, .startNewSession])
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

        XCTAssertEqual(lifecycle.handle(.machineFailed("disk unavailable")), [.cancelForceStop])
        XCTAssertEqual(lifecycle.phase, .failed("disk unavailable"))
        XCTAssertFalse(lifecycle.restartAfterStop)
        XCTAssertEqual(lifecycle.handle(.startRequested), [.startNewSession])
        XCTAssertEqual(lifecycle.phase, .starting)
    }

    func testGracefulStopTimeoutForcesStopOnlyWhileStopping() {
        var lifecycle = runningLifecycle()
        XCTAssertEqual(lifecycle.handle(.stopTimedOut), [])
        _ = lifecycle.handle(.stopRequested)
        XCTAssertEqual(lifecycle.handle(.stopTimedOut), [.forceStop])
        XCTAssertEqual(lifecycle.phase, .stopping)
        XCTAssertEqual(lifecycle.handle(.machineStopped), [.cancelForceStop])
        XCTAssertEqual(lifecycle.handle(.stopTimedOut), [])
    }

    func testCommandChordRedirectsOnlyWhileOmarchyIsFocused() {
        XCTAssertTrue(OmarchyCommandCapturePolicy.shouldRedirect(
            type: .keyDown, keyCode: 49, flags: [.maskCommand], focused: true, isSynthetic: false
        ))
        XCTAssertFalse(OmarchyCommandCapturePolicy.shouldRedirect(
            type: .keyDown, keyCode: 49, flags: [.maskCommand], focused: false, isSynthetic: false
        ))
        XCTAssertFalse(OmarchyCommandCapturePolicy.shouldRedirect(
            type: .keyDown, keyCode: 49, flags: [], focused: true, isSynthetic: false
        ))
    }

    func testSyntheticAndCommandModifierEventsNeverLoopThroughBridge() {
        XCTAssertFalse(OmarchyCommandCapturePolicy.shouldRedirect(
            type: .keyDown, keyCode: 49, flags: [.maskCommand], focused: true, isSynthetic: true
        ))
        XCTAssertFalse(OmarchyCommandCapturePolicy.shouldRedirect(
            type: .flagsChanged, keyCode: 55, flags: [.maskCommand], focused: true, isSynthetic: false
        ))
        XCTAssertFalse(OmarchyCommandCapturePolicy.shouldRedirect(
            type: .keyUp, keyCode: 55, flags: [.maskCommand], focused: true, isSynthetic: false
        ))
    }

    func testIntegrationRequiresDesktopProvisioningAndEverySignedCapability() {
        let required = VMOmarchyProfile.production.requiredGuestCapabilities
        let readyStatus = VMOmarchyGuestStatus(
            agentVersion: "test",
            hostName: "omarchy",
            addresses: ["192.0.2.10"],
            capabilities: Set(required),
            desktopSessionActive: true,
            provisioningPending: false
        )
        XCTAssertTrue(VMOmarchyIntegrationAssessment.evaluate(
            status: readyStatus,
            requiredCapabilities: required
        ).isReady)

        let pending = VMOmarchyGuestStatus(
            agentVersion: "test",
            hostName: "omarchy",
            addresses: [],
            capabilities: Set(required.dropLast()),
            desktopSessionActive: true,
            provisioningPending: true
        )
        let assessment = VMOmarchyIntegrationAssessment.evaluate(
            status: pending,
            requiredCapabilities: required
        )
        XCTAssertFalse(assessment.isReady)
        XCTAssertTrue(assessment.provisioningPending)
        XCTAssertEqual(assessment.missingCapabilities, [required.last!])
    }

    private func runningLifecycle() -> OmarchyMachineLifecycle {
        var lifecycle = OmarchyMachineLifecycle()
        XCTAssertEqual(lifecycle.handle(.machineStarted), [])
        XCTAssertEqual(lifecycle.phase, .running)
        return lifecycle
    }
}
