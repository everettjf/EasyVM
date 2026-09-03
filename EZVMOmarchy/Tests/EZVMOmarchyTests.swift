import XCTest
import EZVMCore
@testable import EZVM_Omarchy

final class EZVMOmarchyTests: XCTestCase {
    func testAcceptanceWorkspaceOverrideRequiresExplicitFlagAndTemporaryRoot() throws {
        let fallback = try OmarchyWorkspaceConfiguration.layout(environment: [:])
        XCTAssertTrue(fallback.applicationSupportRoot.path.hasSuffix("/EZVM Omarchy"))

        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "ezvm-omarchy-acceptance-test")
        let selected = try OmarchyWorkspaceConfiguration.layout(environment: [
            OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1",
            OmarchyWorkspaceConfiguration.acceptanceRootKey: temporary.path,
        ])
        XCTAssertEqual(selected.applicationSupportRoot, temporary.standardizedFileURL)

        let privateTemporary = try OmarchyWorkspaceConfiguration.layout(environment: [
            OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1",
            OmarchyWorkspaceConfiguration.acceptanceRootKey: "/tmp/ezvm-omarchy-acceptance-test",
        ])
        XCTAssertTrue(
            privateTemporary.applicationSupportRoot.path.hasSuffix("/tmp/ezvm-omarchy-acceptance-test")
        )

        XCTAssertThrowsError(try OmarchyWorkspaceConfiguration.layout(environment: [
            OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1",
            OmarchyWorkspaceConfiguration.acceptanceRootKey: "/Users/shared/not-temporary",
        ]))
        XCTAssertEqual(
            OmarchyWorkspaceConfiguration.acceptanceUnlockPasswordKey,
            "EZVM_OMARCHY_ACCEPTANCE_UNLOCK_PASSWORD"
        )
    }

    func testDedicatedAppUsesOmarchyProductIdentity() throws {
        let profile = VMOmarchyProfile.production
        try profile.validate()
        XCTAssertEqual(profile.productID, "com.everettjf.ezvm.omarchy")
    }

    func testReleaseInfoTemplateCarriesFactoryTrustAndSourceProvenance() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let template = testFile.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/Info.plist")
        let values = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: template), format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(values["EZVMOmarchyFactoryPublicKeyBase64"] as? String, "$(EZVM_OMARCHY_FACTORY_PUBLIC_KEY_BASE64)")
        XCTAssertEqual(values["EZVMSourceRevision"] as? String, "$(EZVM_SOURCE_REVISION)")
        XCTAssertEqual(values["EZVMSourceTreeState"] as? String, "$(EZVM_SOURCE_TREE_STATE)")
        XCTAssertEqual(values["ITSAppUsesNonExemptEncryption"] as? Bool, false)
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

    func testAcceptanceObservationRecordsOnlyObservedIntegrationFacts() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let status = VMOmarchyGuestStatus(
            agentVersion: "agent-commit",
            omarchyRevision: "omarchy-commit",
            hostName: "omarchy",
            addresses: ["2001:db8::2", "192.0.2.2"],
            capabilities: [
                "desktop-input-v1", "dynamic-display-v1", "shutdown-v1",
                "shared-folders-v1", "clipboard-text-v1", "clipboard-image-v1",
            ],
            desktopSessionActive: true,
            provisioningPending: false
        )
        let observation = OmarchyAcceptanceObservationReporter.makeObservation(
            status: status,
            requiredCapabilities: VMOmarchyProfile.production.requiredGuestCapabilities,
            factoryImageVersion: "factory-version",
            sourceRevision: "source-commit",
            sharedFolderRoundTrip: VMOmarchySharedFolderRoundTrip(
                observedAt: observedAt,
                hostToGuestSHA256: String(repeating: "a", count: 64),
                guestToHostSHA256: String(repeating: "b", count: 64)
            ),
            clipboardRoundTrip: OmarchyClipboardRoundTrip(
                observedAt: observedAt,
                hostToGuestTextSHA256: String(repeating: "c", count: 64),
                guestToHostTextSHA256: String(repeating: "d", count: 64),
                hostToGuestImageSHA256: String(repeating: "e", count: 64),
                guestToHostImageSHA256: String(repeating: "f", count: 64)
            ),
            observedAt: observedAt
        )

        XCTAssertEqual(observation.schemaVersion, 3)
        XCTAssertEqual(observation.observedAt, observedAt)
        XCTAssertEqual(observation.sourceRevision, "source-commit")
        XCTAssertEqual(observation.factoryImageVersion, "factory-version")
        XCTAssertEqual(observation.guestAgentVersion, "agent-commit")
        XCTAssertEqual(observation.omarchyRevision, "omarchy-commit")
        XCTAssertEqual(observation.guestAddresses, ["192.0.2.2", "2001:db8::2"])
        XCTAssertTrue(observation.desktopSessionActive)
        XCTAssertFalse(observation.provisioningPending)
        XCTAssertTrue(observation.sharedFolderCapabilityAdvertised)
        XCTAssertTrue(observation.clipboardTextCapabilityAdvertised)
        XCTAssertTrue(observation.clipboardImageCapabilityAdvertised)
        XCTAssertTrue(observation.dynamicDisplayCapabilityAdvertised)
        XCTAssertTrue(observation.sharedFolderRoundTripPassed)
        XCTAssertEqual(observation.sharedFolderRoundTripObservedAt, observedAt)
        XCTAssertEqual(observation.hostToGuestSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(observation.guestToHostSHA256, String(repeating: "b", count: 64))
        XCTAssertTrue(observation.clipboardRoundTripPassed)
        XCTAssertEqual(observation.clipboardRoundTripObservedAt, observedAt)
        XCTAssertEqual(observation.hostToGuestTextSHA256, String(repeating: "c", count: 64))
        XCTAssertEqual(observation.guestToHostTextSHA256, String(repeating: "d", count: 64))
        XCTAssertEqual(observation.hostToGuestImageSHA256, String(repeating: "e", count: 64))
        XCTAssertEqual(observation.guestToHostImageSHA256, String(repeating: "f", count: 64))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNoThrow(try decoder.decode(
            OmarchyIntegrationObservation.self, from: observation.encoded()
        ))
    }

    private func runningLifecycle() -> OmarchyMachineLifecycle {
        var lifecycle = OmarchyMachineLifecycle()
        XCTAssertEqual(lifecycle.handle(.machineStarted), [])
        XCTAssertEqual(lifecycle.phase, .running)
        return lifecycle
    }

    @MainActor
    func testApplicationTerminationWaitsForGracefulGuestStop() {
        let machine = MockTerminableMachine(canRequestStop: true, canStop: true)
        var replies: [Bool] = []
        var timeout: DispatchWorkItem?
        let controller = OmarchyApplicationTerminationController(
            reply: { replies.append($0) },
            scheduleTimeout: { timeout = $0 }
        )
        controller.register(machine)

        XCTAssertEqual(controller.requestTermination(), .terminateLater)
        XCTAssertEqual(machine.requestStopCount, 1)
        XCTAssertEqual(machine.forceStopCount, 0)
        XCTAssertTrue(replies.isEmpty)
        XCTAssertNotNil(timeout)

        controller.machineDidStop(machine)
        XCTAssertEqual(replies, [true])
        XCTAssertTrue(timeout?.isCancelled == true)
    }

    @MainActor
    func testViewTeardownAndQuitShareOneShutdownTransaction() {
        let machine = MockTerminableMachine(canRequestStop: true, canStop: true)
        var replies: [Bool] = []
        let controller = OmarchyApplicationTerminationController(
            reply: { replies.append($0) }, scheduleTimeout: { _ in }
        )
        controller.register(machine)
        controller.stopForViewTeardown(machine)
        XCTAssertEqual(machine.requestStopCount, 1)

        XCTAssertEqual(controller.requestTermination(), .terminateLater)
        XCTAssertEqual(machine.requestStopCount, 1)
        XCTAssertTrue(replies.isEmpty)
        controller.machineDidStop(machine)
        XCTAssertEqual(replies, [true])
    }

    @MainActor
    func testGracefulShutdownTimeoutForcesStopBeforeReplying() async {
        let machine = MockTerminableMachine(canRequestStop: true, canStop: true)
        var replies: [Bool] = []
        var timeout: DispatchWorkItem?
        let replied = expectation(description: "application termination replied")
        let controller = OmarchyApplicationTerminationController(
            reply: { replies.append($0); replied.fulfill() }, scheduleTimeout: { timeout = $0 }
        )
        controller.register(machine)
        XCTAssertEqual(controller.requestTermination(), .terminateLater)

        timeout?.perform()
        XCTAssertEqual(machine.forceStopCount, 1)
        XCTAssertTrue(replies.isEmpty)
        machine.completeForcedStop()
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(replies, [true])
    }
}

private final class MockTerminableMachine: OmarchyTerminableMachine {
    let canRequestStop: Bool
    let canStop: Bool
    private(set) var requestStopCount = 0
    private(set) var forceStopCount = 0
    private var completion: ((Error?) -> Void)?

    init(canRequestStop: Bool, canStop: Bool) {
        self.canRequestStop = canRequestStop
        self.canStop = canStop
    }

    func requestStop() throws { requestStopCount += 1 }

    func stop(completionHandler: @escaping (Error?) -> Void) {
        forceStopCount += 1
        completion = completionHandler
    }

    func completeForcedStop(error: Error? = nil) {
        let callback = completion
        completion = nil
        callback?(error)
    }
}
