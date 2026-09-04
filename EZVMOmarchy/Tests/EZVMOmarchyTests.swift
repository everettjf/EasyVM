import CoreGraphics
import XCTest
import EZVMCore
@testable import EZVM_Omarchy

final class EZVMOmarchyTests: XCTestCase {
    func testInputDiagnosticsProbeCapturesHyprlandBindingAndDeviceState() {
        let script = OmarchyInputDiagnosticsAcceptanceProbe.probeScript(
            resultPath: "/mnt/ezvm-shared/result.txt"
        )

        XCTAssertTrue(script.contains("hyprctl binds -j"))
        XCTAssertTrue(script.contains("hyprctl devices -j"))
        XCTAssertTrue(script.contains("hyprctl activewindow -j"))
        XCTAssertTrue(script.contains("omarchy-shell lock status"))
        XCTAssertTrue(script.contains("pgrep -a omarchy-shell"))
        XCTAssertTrue(script.contains("result='/mnt/ezvm-shared/result.txt'"))
        XCTAssertTrue(script.contains("mv -f -- \"$partial\" \"$result\""))

        let watcher = OmarchyInputDiagnosticsAcceptanceProbe.lockWatcherScript(
            guestDirectory: "/mnt/ezvm-shared/probe"
        )
        XCTAssertTrue(watcher.contains("omarchy-shell lock isLocked"))
        XCTAssertTrue(watcher.contains("touch \"$d/locked\""))
        XCTAssertTrue(watcher.contains("touch \"$d/unlocked\""))
    }

    func testLockWatcherSeparatesChordRecognitionFromOmarchyLockAction() {
        let script = OmarchyInputDiagnosticsAcceptanceProbe.lockWatcherScript(
            guestDirectory: "/mnt/ezvm-shared/probe"
        )
        XCTAssertTrue(script.contains("command -v omarchy-shell"))
        XCTAssertTrue(script.contains("OMARCHY_SHELL_IPC_TIMEOUT=0.5s"))
        XCTAssertTrue(script.contains("[[ $state == true || $state == false ]]"))
        XCTAssertFalse(script.contains("hyprlock"))
    }

    @MainActor
    func testClipboardProbeWaitsForGuestScriptAndMatchingPasteboardPayloads() {
        let script = OmarchyClipboardAcceptanceProbe.probeScript(
            guestDirectory: "/mnt/ezvm-shared/probe"
        )

        XCTAssertTrue(script.contains("touch \"$d/script-ready\""))
        XCTAssertTrue(script.contains(
            "copy_until_matches \"$d/host-text-input\" \"$d/host-text-result\" --type 'text/plain;charset=utf-8' --no-newline"
        ))
        XCTAssertTrue(script.contains("cat \"$d/guest-text-input\" | /usr/bin/wl-copy --foreground --type 'text/plain;charset=utf-8'"))
        XCTAssertTrue(script.contains("cat \"$d/guest-image-input\" | /usr/bin/wl-copy --foreground --type image/png"))
        XCTAssertFalse(script.contains("native-wayland-result"))
        XCTAssertTrue(script.contains("copy_until_matches \"$d/host-image-input\""))
        XCTAssertTrue(script.contains("cmp -s \"$expected\" \"$local_part\""))
        XCTAssertTrue(script.contains("${XDG_RUNTIME_DIR:-/tmp}/ezvm-clipboard-probe.$$.part"))
        XCTAssertTrue(script.contains("guest-clipboard-types"))
    }

    func testAcceptanceUnlockCredentialRequiresAcceptanceMode() {
        XCTAssertNil(OmarchyAcceptanceUnlockCredential(environment: [
            OmarchyWorkspaceConfiguration.acceptanceUnlockPasswordKey: "123456"
        ]))
        XCTAssertEqual(OmarchyAcceptanceUnlockCredential(environment: [
            OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1",
            OmarchyWorkspaceConfiguration.acceptanceUnlockPasswordKey: "123456"
        ])?.password, "123456")
    }

    func testOwnerSetupBuildsOnePasswordRequestAndClearsSecrets() throws {
        var form = OmarchyOwnerSetupForm()
        form.password = "temporary-密碼"
        form.passwordConfirmation = form.password
        form.fullName = "Omarchy Owner"
        form.emailAddress = "owner@example.com"
        form.timezone = "America/Los_Angeles"

        let request = try form.validatedRequest()
        XCTAssertEqual(request.username, "omarchy")
        XCTAssertEqual(request.password, "temporary-密碼")
        XCTAssertEqual(request.keyboard, "us")
        XCTAssertEqual(request.timezone, "America/Los_Angeles")

        form.clearSecrets()
        XCTAssertTrue(form.password.isEmpty)
        XCTAssertTrue(form.passwordConfirmation.isEmpty)
        XCTAssertEqual(form.username, "omarchy")
    }

    func testOwnerSetupRejectsMismatchReservedNamesAndUnsafeFields() {
        var form = OmarchyOwnerSetupForm()
        form.password = "temporary-password"
        form.passwordConfirmation = "different"
        XCTAssertThrowsError(try form.validatedRequest()) {
            XCTAssertEqual($0 as? OmarchyOwnerSetupForm.ValidationError, .passwordsDoNotMatch)
        }

        form.passwordConfirmation = form.password
        form.username = "root"
        XCTAssertThrowsError(try form.validatedRequest()) {
            XCTAssertEqual($0 as? OmarchyOwnerSetupForm.ValidationError, .invalidUsername)
        }

        form.username = "omarchy"
        form.hostname = "-invalid"
        XCTAssertThrowsError(try form.validatedRequest()) {
            XCTAssertEqual($0 as? OmarchyOwnerSetupForm.ValidationError, .invalidHostname)
        }

        form.hostname = "omarchy"
        form.fullName = "Injected\nName"
        XCTAssertThrowsError(try form.validatedRequest()) {
            XCTAssertEqual($0 as? OmarchyOwnerSetupForm.ValidationError, .invalidIdentity)
        }
    }

    func testOwnerSetupKeyboardCodesAreUniqueAndMatchFactoryChoices() {
        let layouts = OmarchyOwnerSetupForm.keyboardLayouts
        XCTAssertEqual(Set(layouts.map(\.label)).count, layouts.count)
        XCTAssertEqual(layouts.first?.code, "us")
        XCTAssertTrue(layouts.contains(where: { $0.code == "jp106" }))
        XCTAssertTrue(layouts.contains(where: { $0.code == "br-abnt2" }))
    }

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

    func testAutomaticOwnerPasswordRequiresValidTemporaryAcceptanceWorkspace() {
        let password = "temporary-密碼"
        XCTAssertNil(OmarchyWorkspaceConfiguration.acceptanceOwnerProvisioningPassword(
            environment: [OmarchyWorkspaceConfiguration.acceptanceUnlockPasswordKey: password]
        ))
        XCTAssertNil(OmarchyWorkspaceConfiguration.acceptanceOwnerProvisioningPassword(environment: [
            OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1",
            OmarchyWorkspaceConfiguration.acceptanceRootKey: "/Users/shared/not-temporary",
            OmarchyWorkspaceConfiguration.acceptanceUnlockPasswordKey: password,
        ]))
        XCTAssertEqual(OmarchyWorkspaceConfiguration.acceptanceOwnerProvisioningPassword(environment: [
            OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1",
            OmarchyWorkspaceConfiguration.acceptanceRootKey: "/tmp/ezvm-owner-acceptance",
            OmarchyWorkspaceConfiguration.acceptanceUnlockPasswordKey: password,
        ]), password)
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

    func testPauseAndResumeRequireCompletedMachineTransitions() {
        var lifecycle = runningLifecycle()

        XCTAssertEqual(lifecycle.handle(.pauseRequested), [.requestPause])
        XCTAssertEqual(lifecycle.phase, .pausing)
        XCTAssertEqual(lifecycle.handle(.pauseRequested), [])
        XCTAssertEqual(lifecycle.handle(.resumeRequested), [])

        XCTAssertEqual(lifecycle.handle(.machinePaused), [])
        XCTAssertEqual(lifecycle.phase, .paused)
        XCTAssertEqual(lifecycle.handle(.resumeRequested), [.requestResume])
        XCTAssertEqual(lifecycle.phase, .resuming)
        XCTAssertEqual(lifecycle.handle(.resumeRequested), [])

        XCTAssertEqual(lifecycle.handle(.machineStarted), [])
        XCTAssertEqual(lifecycle.phase, .running)
    }

    func testPausedMachineCanStopOrRestartWithoutResuming() {
        var stopping = runningLifecycle()
        _ = stopping.handle(.pauseRequested)
        _ = stopping.handle(.machinePaused)
        XCTAssertEqual(stopping.handle(.stopRequested), [.requestStop, .scheduleForceStop])
        XCTAssertEqual(stopping.phase, .stopping)

        var restarting = runningLifecycle()
        _ = restarting.handle(.pauseRequested)
        _ = restarting.handle(.machinePaused)
        XCTAssertEqual(restarting.handle(.restartRequested), [.requestStop, .scheduleForceStop])
        XCTAssertTrue(restarting.restartAfterStop)
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

    func testCommandSpaceCaptureRequiresOrderedDownAndUp() {
        var state = OmarchyCommandSpaceCaptureState()
        XCTAssertFalse(state.observe(type: .keyUp, keyCode: 49))
        XCTAssertFalse(state.observe(type: .keyDown, keyCode: 0))
        XCTAssertFalse(state.observe(type: .keyDown, keyCode: 49))
        XCTAssertTrue(state.observe(type: .keyUp, keyCode: 49))
        XCTAssertFalse(state.observe(type: .keyUp, keyCode: 49))
    }

    func testCommandSuperObservationIsBoundToRuntimeState() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ezvm-command-super-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        OmarchyAcceptanceObservationReporter.reportCommandSuperIfEnabled(
            layout: layout,
            applicationActive: true,
            virtualMachineWindowKey: true,
            environment: [OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1"],
            bundleInfo: ["EZVMSourceRevision": "revision"]
        )
        let data = try Data(contentsOf: layout.diagnostics.appending(
            path: OmarchyAcceptanceObservationReporter.commandSuperFileName
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["sourceRevision"] as? String, "revision")
        XCTAssertEqual(json["eventTapEnabled"] as? Bool, true)
        XCTAssertEqual(json["commandSpaceKeyDownAndUpCaptured"] as? Bool, true)
        XCTAssertEqual(json["applicationActiveAfterCapture"] as? Bool, true)
        XCTAssertEqual(json["virtualMachineWindowKeyAfterCapture"] as? Bool, true)
    }

    func testFullScreenTransitionRequiresOrderedEnterAndExit() {
        var state = OmarchyFullScreenTransitionState()
        let entered = Date(timeIntervalSince1970: 10)
        let exited = Date(timeIntervalSince1970: 11)
        XCTAssertFalse(state.observeExited(at: exited))
        XCTAssertTrue(state.observeEntered(at: entered))
        XCTAssertFalse(state.observeEntered(at: entered))
        XCTAssertTrue(state.observeExited(at: exited))
        XCTAssertFalse(state.observeExited(at: exited))
        XCTAssertEqual(state.enteredAt, entered)
        XCTAssertEqual(state.exitedAt, exited)
    }

    func testLockAcceptanceRequiresLockedThenActiveStatus() {
        let pending = VMOmarchyGuestStatus(
            agentVersion: "agent", hostName: "omarchy", addresses: [], capabilities: [],
            desktopSessionActive: false, provisioningPending: true
        )
        let active = VMOmarchyGuestStatus(
            agentVersion: "agent", hostName: "omarchy", addresses: [], capabilities: [],
            desktopSessionActive: true, provisioningPending: false
        )
        let locked = VMOmarchyGuestStatus(
            agentVersion: "agent", hostName: "omarchy", addresses: [], capabilities: [],
            desktopSessionActive: false, provisioningPending: false
        )
        var state = OmarchyLockAcceptanceState()
        XCTAssertEqual(state.observe(locked), .none)
        XCTAssertTrue(state.begin())
        XCTAssertFalse(state.begin())
        XCTAssertEqual(state.observe(active), .none)
        XCTAssertEqual(state.observe(pending), .none)
        XCTAssertEqual(state.observe(locked), .submitUnlockSecret)
        XCTAssertEqual(state.observe(locked), .none)
        XCTAssertEqual(state.observe(active), .completed)
        XCTAssertEqual(state.observe(active), .none)
        XCTAssertEqual(state.phase, .complete)
    }

    func testLockAcceptanceTimeoutFailsOnlyAnInFlightProbe() {
        var state = OmarchyLockAcceptanceState()
        XCTAssertFalse(state.timeout())
        XCTAssertTrue(state.begin())
        XCTAssertTrue(state.timeout())
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.timeout())

        XCTAssertTrue(state.begin())
        let locked = VMOmarchyGuestStatus(
            agentVersion: "agent", hostName: "omarchy", addresses: [], capabilities: [],
            desktopSessionActive: false, provisioningPending: false
        )
        XCTAssertEqual(state.observe(locked), .submitUnlockSecret)
        XCTAssertTrue(state.timeout())
        XCTAssertEqual(state.phase, .idle)
    }

    func testAcceptanceUnlockCredentialIsScopedAndBounded() {
        let enabled = OmarchyWorkspaceConfiguration.acceptanceEnabledKey
        let password = OmarchyWorkspaceConfiguration.acceptanceUnlockPasswordKey
        XCTAssertNil(OmarchyAcceptanceUnlockCredential(environment: [password: "test"]))
        XCTAssertNil(OmarchyAcceptanceUnlockCredential(environment: [enabled: "1"]))
        XCTAssertNil(OmarchyAcceptanceUnlockCredential(environment: [enabled: "1", password: ""]))
        XCTAssertNil(OmarchyAcceptanceUnlockCredential(environment: [
            enabled: "1", password: String(repeating: "a", count: 129)
        ]))
        XCTAssertNil(OmarchyAcceptanceUnlockCredential(environment: [enabled: "1", password: "line\nfeed"]))
        XCTAssertNil(OmarchyAcceptanceUnlockCredential(environment: [enabled: "1", password: "密碼"]))
        XCTAssertEqual(
            OmarchyAcceptanceUnlockCredential(environment: [enabled: "1", password: "test-123!"])?.password,
            "test-123!"
        )
    }

    func testFullScreenObservationIsBoundToRuntimeState() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ezvm-full-screen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        OmarchyAcceptanceObservationReporter.reportFullScreenIfEnabled(
            layout: layout,
            enteredAt: Date(timeIntervalSince1970: 10),
            exitedAt: Date(timeIntervalSince1970: 11),
            applicationActive: true,
            virtualMachineWindowKey: true,
            virtualMachineViewFocused: true,
            environment: [OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1"],
            bundleInfo: ["EZVMSourceRevision": "revision"]
        )
        let data = try Data(contentsOf: layout.diagnostics.appending(
            path: OmarchyAcceptanceObservationReporter.fullScreenFileName
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["sourceRevision"] as? String, "revision")
        XCTAssertEqual(json["enteredAndExitedFullScreen"] as? Bool, true)
        XCTAssertEqual(json["applicationActiveAfterExit"] as? Bool, true)
        XCTAssertEqual(json["virtualMachineWindowKeyAfterExit"] as? Bool, true)
        XCTAssertEqual(json["virtualMachineViewFocusedAfterExit"] as? Bool, true)
    }

    func testSoakHeartbeatRecordsAuthenticatedGuestContinuity() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ezvm-soak-heartbeat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        let status = VMOmarchyGuestStatus(
            agentVersion: "agent", agentInstanceID: "instance", bootID: "boot",
            uptimeSeconds: 1234, hostName: "omarchy", addresses: [], capabilities: [],
            desktopSessionActive: true, provisioningPending: false
        )
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: status,
            layout: layout,
            environment: [OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1"],
            bundleInfo: ["EZVMSourceRevision": "revision"]
        )
        let data = try Data(contentsOf: layout.diagnostics.appending(
            path: OmarchyAcceptanceObservationReporter.soakHeartbeatFileName
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["sourceRevision"] as? String, "revision")
        XCTAssertEqual(json["guestAgentVersion"] as? String, "agent")
        XCTAssertEqual(json["agentInstanceID"] as? String, "instance")
        XCTAssertEqual(json["bootID"] as? String, "boot")
        XCTAssertEqual(json["uptimeSeconds"] as? Int, 1234)
        XCTAssertEqual(json["desktopSessionActive"] as? Bool, true)
        XCTAssertEqual(json["provisioningPending"] as? Bool, false)
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
                "agent-restart-v1", "desktop-input-v1", "dynamic-display-v1", "shutdown-v1",
                "shared-folders-v1", "clipboard-text-v1", "clipboard-image-v1",
            ],
            desktopSessionActive: true,
            provisioningPending: false
        )
        let observation = OmarchyAcceptanceObservationReporter.makeObservation(
            status: status,
            requiredCapabilities: VMOmarchyProfile.production.requiredGuestCapabilities,
            workspaceCreatedAt: observedAt.addingTimeInterval(-60),
            factoryImageVersion: "factory-version",
            sourceRevision: "source-commit",
            sharedFolderRoundTrip: VMOmarchySharedFolderRoundTrip(
                observedAt: observedAt,
                hostToGuestSHA256: String(repeating: "a", count: 64),
                guestToHostSHA256: String(repeating: "b", count: 64),
                fileImportObservedAt: observedAt,
                importedFileSHA256: String(repeating: "c", count: 64)
            ),
            clipboardRoundTrip: OmarchyClipboardRoundTrip(
                observedAt: observedAt,
                hostToGuestTextSHA256: String(repeating: "c", count: 64),
                guestToHostTextSHA256: String(repeating: "d", count: 64),
                hostToGuestImageSHA256: String(repeating: "e", count: 64),
                guestToHostImageSHA256: String(repeating: "f", count: 64)
            ),
            dynamicDisplayRoundTrip: OmarchyDynamicDisplayRoundTrip(
                observedAt: observedAt,
                guestBefore: .init(width: 1920, height: 1200),
                guestAfter: .init(width: 880, height: 560),
                hostViewAfter: .init(width: 880, height: 560)
            ),
            observedAt: observedAt
        )

        XCTAssertEqual(observation.schemaVersion, 5)
        XCTAssertEqual(observation.observedAt, observedAt)
        XCTAssertEqual(observation.sourceRevision, "source-commit")
        XCTAssertEqual(observation.factoryImageVersion, "factory-version")
        XCTAssertEqual(observation.workspaceCreatedAt, observedAt.addingTimeInterval(-60))
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
        XCTAssertTrue(observation.fileImportPassed)
        XCTAssertEqual(observation.fileImportObservedAt, observedAt)
        XCTAssertEqual(observation.importedFileSHA256, String(repeating: "c", count: 64))
        XCTAssertEqual(observation.sharedFolderRoundTripObservedAt, observedAt)
        XCTAssertEqual(observation.hostToGuestSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(observation.guestToHostSHA256, String(repeating: "b", count: 64))
        XCTAssertTrue(observation.clipboardRoundTripPassed)
        XCTAssertEqual(observation.clipboardRoundTripObservedAt, observedAt)
        XCTAssertEqual(observation.hostToGuestTextSHA256, String(repeating: "c", count: 64))
        XCTAssertEqual(observation.guestToHostTextSHA256, String(repeating: "d", count: 64))
        XCTAssertEqual(observation.hostToGuestImageSHA256, String(repeating: "e", count: 64))
        XCTAssertEqual(observation.guestToHostImageSHA256, String(repeating: "f", count: 64))
        XCTAssertTrue(observation.dynamicDisplayRoundTripPassed)
        XCTAssertEqual(observation.dynamicDisplayRoundTripObservedAt, observedAt)
        XCTAssertEqual(observation.guestDisplayBefore, .init(width: 1920, height: 1200))
        XCTAssertEqual(observation.guestDisplayAfter, .init(width: 880, height: 560))
        XCTAssertEqual(observation.hostViewAfter, .init(width: 880, height: 560))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNoThrow(try decoder.decode(
            OmarchyIntegrationObservation.self, from: observation.encoded()
        ))
    }

    func testAcceptanceLifecyclePreservesLockedThenUnlockedEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ezvm-omarchy-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        let environment = [OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1"]
        let provisioningAt = Date(timeIntervalSince1970: 1_699_999_990)
        let lockedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let unlockedAt = lockedAt.addingTimeInterval(10)
        let pauseRequestedAt = unlockedAt.addingTimeInterval(10)
        let pausedAt = pauseRequestedAt.addingTimeInterval(1)
        let resumedAt = pausedAt.addingTimeInterval(2)
        let recoveredAt = resumedAt.addingTimeInterval(3)
        let agentRestartAt = recoveredAt.addingTimeInterval(1)
        let agentDisconnectedAt = agentRestartAt.addingTimeInterval(1)
        let agentRecoveredAt = agentDisconnectedAt.addingTimeInterval(3)
        let guestRestartAt = agentRecoveredAt.addingTimeInterval(1)
        let guestDisconnectedAt = guestRestartAt.addingTimeInterval(1)
        let guestRecoveredAt = guestDisconnectedAt.addingTimeInterval(8)
        let hostSleepAt = guestRecoveredAt.addingTimeInterval(10)
        let hostWakeAt = hostSleepAt.addingTimeInterval(4)
        let hostRecoveredAt = hostWakeAt.addingTimeInterval(3)
        let provisioning = VMOmarchyGuestStatus(
            agentVersion: "agent-commit",
            hostName: "omarchy",
            addresses: [],
            capabilities: [],
            desktopSessionActive: false,
            provisioningPending: true
        )
        let locked = VMOmarchyGuestStatus(
            agentVersion: "agent-commit",
            hostName: "omarchy",
            addresses: [],
            capabilities: [],
            desktopSessionActive: false,
            provisioningPending: false
        )
        let unlocked = VMOmarchyGuestStatus(
            agentVersion: "agent-commit",
            agentInstanceID: "instance-before",
            bootID: "boot-before",
            hostName: "omarchy",
            addresses: [],
            capabilities: [],
            desktopSessionActive: true,
            provisioningPending: false
        )
        let agentRecovered = VMOmarchyGuestStatus(
            agentVersion: "agent-commit", agentInstanceID: "instance-after",
            bootID: "boot-before", hostName: "omarchy", addresses: [], capabilities: [],
            desktopSessionActive: true, provisioningPending: false
        )
        let guestRecovered = VMOmarchyGuestStatus(
            agentVersion: "agent-commit", agentInstanceID: "instance-after-boot",
            bootID: "boot-after", hostName: "omarchy", addresses: [], capabilities: [],
            desktopSessionActive: true, provisioningPending: false
        )

        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: provisioning,
            layout: layout,
            environment: environment,
            observedAt: provisioningAt
        )
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: locked, layout: layout, environment: environment, observedAt: lockedAt
        )
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: unlocked, layout: layout, environment: environment, observedAt: unlockedAt
        )
        OmarchyAcceptanceObservationReporter.reportVirtualMachineEventIfEnabled(
            .pauseRequested, layout: layout, environment: environment, observedAt: pauseRequestedAt
        )
        OmarchyAcceptanceObservationReporter.reportVirtualMachineEventIfEnabled(
            .paused, layout: layout, environment: environment, observedAt: pausedAt
        )
        OmarchyAcceptanceObservationReporter.reportVirtualMachineEventIfEnabled(
            .resumed, layout: layout, environment: environment, observedAt: resumedAt
        )
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: unlocked, layout: layout, environment: environment, observedAt: recoveredAt
        )
        OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
            .agentRestartRequested(unlocked), layout: layout, environment: environment,
            observedAt: agentRestartAt
        )
        OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
            .disconnectedAfterAgentRestart, layout: layout, environment: environment,
            observedAt: agentDisconnectedAt
        )
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: agentRecovered, layout: layout, environment: environment,
            observedAt: agentRecoveredAt
        )
        OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
            .guestRestartRequested(agentRecovered), layout: layout, environment: environment,
            observedAt: guestRestartAt
        )
        OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
            .disconnectedAfterGuestRestart, layout: layout, environment: environment,
            observedAt: guestDisconnectedAt
        )
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: guestRecovered, layout: layout, environment: environment,
            observedAt: guestRecoveredAt
        )
        OmarchyAcceptanceObservationReporter.reportHostPowerEventIfEnabled(
            .willSleep, layout: layout, environment: environment, observedAt: hostSleepAt
        )
        OmarchyAcceptanceObservationReporter.reportHostPowerEventIfEnabled(
            .didWake, layout: layout, environment: environment, observedAt: hostWakeAt
        )
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: guestRecovered, layout: layout, environment: environment, observedAt: hostRecoveredAt
        )

        let data = try Data(contentsOf: layout.diagnostics.appending(
            path: OmarchyAcceptanceObservationReporter.lifecycleFileName
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 5)
        XCTAssertNotNil(json["firstProvisioningPendingObservedAt"])
        XCTAssertNotNil(json["firstLockedObservedAt"])
        XCTAssertNotNil(json["firstActiveObservedAt"])
        XCTAssertNotNil(json["firstActiveAfterLockedObservedAt"])
        XCTAssertNotNil(json["firstPauseRequestedAt"])
        XCTAssertNotNil(json["firstPausedAt"])
        XCTAssertNotNil(json["firstResumedAt"])
        XCTAssertNotNil(json["firstActiveAfterResumeObservedAt"])
        XCTAssertNotNil(json["firstAgentRestartRequestedAt"])
        XCTAssertNotNil(json["firstAgentDisconnectedAfterRestartAt"])
        XCTAssertNotNil(json["firstAgentRecoveredAt"])
        XCTAssertEqual(json["agentBootIDBeforeRestart"] as? String, "boot-before")
        XCTAssertEqual(json["agentBootIDAfterRestart"] as? String, "boot-before")
        XCTAssertEqual(json["agentInstanceIDBeforeRestart"] as? String, "instance-before")
        XCTAssertEqual(json["agentInstanceIDAfterRestart"] as? String, "instance-after")
        XCTAssertNotNil(json["firstGuestRestartRequestedAt"])
        XCTAssertNotNil(json["firstGuestDisconnectedAfterRestartAt"])
        XCTAssertNotNil(json["firstGuestRecoveredAt"])
        XCTAssertEqual(json["guestBootIDBeforeRestart"] as? String, "boot-before")
        XCTAssertEqual(json["guestBootIDAfterRestart"] as? String, "boot-after")
        XCTAssertNotNil(json["firstHostSleepObservedAt"])
        XCTAssertNotNil(json["firstHostWakeObservedAt"])
        XCTAssertNotNil(json["firstActiveAfterHostWakeObservedAt"])
        XCTAssertEqual(json["lastDesktopSessionActive"] as? Bool, true)
        XCTAssertEqual(json["lastProvisioningPending"] as? Bool, false)
        XCTAssertEqual(json["guestAgentVersion"] as? String, "agent-commit")
    }

    func testAcceptanceLifecycleReplacesLegacySchemaBeforeRecordingEvents() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ezvm-omarchy-lifecycle-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        try FileManager.default.createDirectory(at: layout.diagnostics, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":3,"guestAgentVersion":"legacy"}"#.utf8).write(
            to: layout.diagnostics.appending(
                path: OmarchyAcceptanceObservationReporter.lifecycleFileName
            )
        )
        let status = VMOmarchyGuestStatus(
            agentVersion: "current",
            hostName: "omarchy",
            addresses: [],
            capabilities: [],
            desktopSessionActive: false,
            provisioningPending: true
        )

        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: status,
            layout: layout,
            environment: [OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1"]
        )

        let data = try Data(contentsOf: layout.diagnostics.appending(
            path: OmarchyAcceptanceObservationReporter.lifecycleFileName
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 5)
        XCTAssertEqual(json["guestAgentVersion"] as? String, "current")
        XCTAssertNotNil(json["firstProvisioningPendingObservedAt"])
    }

    @MainActor
    func testDynamicDisplayProbeDecodesActiveHyprlandMonitor() throws {
        let data = Data(#"[{"disabled":true,"width":1,"height":1},{"disabled":false,"width":1440,"height":900}]"#.utf8)
        XCTAssertEqual(
            try OmarchyDynamicDisplayAcceptanceProbe.decodeDisplay(data),
            OmarchyDisplaySize(width: 1440, height: 900)
        )
        XCTAssertThrowsError(try OmarchyDynamicDisplayAcceptanceProbe.decodeDisplay(Data("[]".utf8)))
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
