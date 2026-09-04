import CryptoKit
import XCTest
@testable import EZVMCore

final class VMGuestAgentProtocolTests: XCTestCase {
    func testClipboardLoggingTreatsGuestReadMissesAsIdleState() {
        XCTAssertFalse(VMOmarchyGuestAgentClient.shouldLogClipboardResult(operation: .clipboardGet))
        XCTAssertTrue(VMOmarchyGuestAgentClient.shouldLogClipboardResult(operation: .clipboardSet))
    }

    func testLinuxKeyboardTextEncoderProducesBalancedBatches() throws {
        let nonce = UUID().uuidString.lowercased()
        let batches = try VMLinuxKeyboardTextEncoder.batches(
            for: "bash /mnt/ezvm-shared/.ezvm-clipboard-\(nonce)/probe.sh\n"
        )
        XCTAssertFalse(batches.isEmpty)
        XCTAssertTrue(batches.allSatisfy { !$0.events.isEmpty })
        XCTAssertTrue(batches.allSatisfy {
            $0.events.count <= VMGuestAgentInputBatch.maximumEventCount
        })
        let events = batches.flatMap(\.events)
        XCTAssertEqual(events.filter { $0.type == 1 && $0.value == 1 }.count,
                       events.filter { $0.type == 1 && $0.value == 0 }.count)
        XCTAssertEqual(events.last, VMGuestAgentInputEvent(type: 0, code: 0, value: 0))
    }

    func testLinuxKeyboardTextEncoderRejectsUnsupportedCharacters() {
        XCTAssertThrowsError(try VMLinuxKeyboardTextEncoder.batches(for: "é")) { error in
            XCTAssertEqual(
                error as? VMLinuxKeyboardTextEncoder.EncodingError,
                .unsupportedCharacter("é")
            )
            XCTAssertTrue(error.localizedDescription.contains("U+00E9"))
        }
    }

    func testLinuxKeyboardTextEncoderSupportsDiagnosticShellPunctuation() throws {
        let command = "{ systemctl --user status ezvm-session-agent.service; ps -ef | grep '[e]zvm-agent'; } > /tmp/session.txt 2>&1\n"
        let events = try VMLinuxKeyboardTextEncoder.events(for: command)
        XCTAssertFalse(events.isEmpty)
        XCTAssertEqual(events.filter { $0.type == 1 && $0.value == 1 }.count,
                       events.filter { $0.type == 1 && $0.value == 0 }.count)
    }

    func testRetryPolicyUsesBoundedExponentialBackoff() {
        let policy = VMGuestAgentRetryPolicy(maximumDelay: 30)
        XCTAssertEqual(policy.delay(afterFailureCount: 0), 0)
        XCTAssertEqual(policy.delay(afterFailureCount: 1), 1)
        XCTAssertEqual(policy.delay(afterFailureCount: 2), 2)
        XCTAssertEqual(policy.delay(afterFailureCount: 3), 4)
        XCTAssertEqual(policy.delay(afterFailureCount: 6), 30)
        XCTAssertEqual(policy.delay(afterFailureCount: 50), 30)
    }

    func testDisplayResolutionHysteresisIgnoresWindowChromeJitter() {
        let current = (width: UInt32(1920), height: UInt32(1080))
        let chromeCandidate = (width: UInt32(1968), height: UInt32(1080))
        let stable = VMDisplayGeometry.stabilizedResolution(
            candidate: chromeCandidate,
            current: current
        )
        XCTAssertEqual(stable.width, 1920)
        XCTAssertEqual(stable.height, 1080)

        let portraitCandidate = (width: UInt32(1280), height: UInt32(1600))
        let changed = VMDisplayGeometry.stabilizedResolution(
            candidate: portraitCandidate,
            current: current
        )
        XCTAssertEqual(changed.width, 1280)
        XCTAssertEqual(changed.height, 1600)
    }

    func testGuestResolutionUsesLogicalWindowSizeWhileMetalRetainsRetinaPixels() {
        let normal = VMDisplayGeometry.guestResolution(
            for: CGSize(width: 991.6, height: 707.8)
        )
        XCTAssertEqual(normal.width, 992)
        XCTAssertEqual(normal.height, 704)

        let fullscreen = VMDisplayGeometry.guestResolution(
            for: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(fullscreen.width, 1920)
        XCTAssertEqual(fullscreen.height, 1080)
    }

    func testGuestResolutionClampsAndStabilizesDimensions() {
        let tiny = VMDisplayGeometry.guestResolution(for: CGSize(width: 200, height: 100))
        XCTAssertEqual(tiny.width, 640)
        XCTAssertEqual(tiny.height, 360)
        let huge = VMDisplayGeometry.guestResolution(for: CGSize(width: 20_000, height: 20_001))
        XCTAssertEqual(huge.width, 8192)
        XCTAssertEqual(huge.height, 8192)

		let portrait = VMDisplayGeometry.guestResolution(for: CGSize(width: 900, height: 1200))
		XCTAssertEqual(portrait.width, 896)
		XCTAssertEqual(portrait.height, 1200)
    }

    func testVirGLPresentationPreservesGuestAspectRatio() {
        let fitted = VMDisplayGeometry.aspectFit(
            content: CGSize(width: 1920, height: 1080),
            in: CGRect(x: 0, y: 0, width: 1800, height: 1300)
        )
        XCTAssertEqual(fitted.width, 1800, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 1012.5, accuracy: 0.001)
        XCTAssertEqual(fitted.minY, 143.75, accuracy: 0.001)
    }

    func testAbsolutePointerMapsPresentationCoordinatesIntoLinuxRange() {
        let frame = CGRect(x: 100, y: 50, width: 800, height: 600)
        let topLeft = VMAbsolutePointerMapper.coordinates(
            for: CGPoint(x: 100, y: 650), in: frame
        )
        XCTAssertEqual(topLeft?.x, 0)
        XCTAssertEqual(topLeft?.y, 0)

        let center = VMAbsolutePointerMapper.coordinates(
            for: CGPoint(x: 500, y: 350), in: frame
        )
        XCTAssertEqual(center?.x, 16_384)
        XCTAssertEqual(center?.y, 16_384)

        let bottomRight = VMAbsolutePointerMapper.coordinates(
            for: CGPoint(x: 900, y: 50), in: frame
        )
        XCTAssertEqual(bottomRight?.x, 32_767)
        XCTAssertEqual(bottomRight?.y, 32_767)
        XCTAssertNil(VMAbsolutePointerMapper.coordinates(
            for: CGPoint(x: 99, y: 350), in: frame
        ))

        XCTAssertEqual(
            VMAbsolutePointerMapper.events(x: 12, y: 34),
            [
                VMGuestAgentInputEvent(type: 3, code: 0, value: 12),
                VMGuestAgentInputEvent(type: 3, code: 1, value: 34),
                VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
            ]
        )
    }

    func testPreciseScrollingAccumulatesFractionalTrackpadDeltas() {
        var accumulator = VMScrollWheelAccumulator()
        XCTAssertEqual(accumulator.consume(delta: 1.25, hasPreciseDeltas: true), 0)
        XCTAssertEqual(accumulator.consume(delta: 1.25, hasPreciseDeltas: true), 0)
        XCTAssertEqual(accumulator.consume(delta: 1.25, hasPreciseDeltas: true), 1)
        XCTAssertEqual(accumulator.consume(delta: -6.75, hasPreciseDeltas: true), -2)
        XCTAssertEqual(accumulator.consume(delta: 2, hasPreciseDeltas: false), 2)
        XCTAssertEqual(accumulator.consume(delta: -1_050, hasPreciseDeltas: true), -16)
        XCTAssertEqual(accumulator.consume(delta: 0, hasPreciseDeltas: true), 0)
        XCTAssertEqual(accumulator.consume(delta: 500, hasPreciseDeltas: false), 16)
    }

    private let token = Data(repeating: 0x5a, count: 32)
    private let machineID = "machine-a"
    private let guestNonce = Data(repeating: 0x11, count: 32).base64EncodedString()
    private let hostNonce = Data(repeating: 0x22, count: 32).base64EncodedString()

    func testInputBatchProducesLinuxKeyAndSynchronizationEvents() throws {
        let down = VMGuestAgentInputBatch.key(code: 28, pressed: true)
        XCTAssertEqual(down.events, [
            VMGuestAgentInputEvent(type: 1, code: 28, value: 1),
            VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
        ])
        let decoded = try JSONDecoder().decode(
            VMGuestAgentInputBatch.self,
            from: JSONEncoder().encode(down)
        )
        XCTAssertEqual(decoded, down)
        XCTAssertEqual(VMGuestAgentInputBatch.maximumEventCount, 64)
        XCTAssertEqual(VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: 36), 28)
        XCTAssertEqual(VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: 0), 30)
        XCTAssertEqual(VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: 117), 111)
        XCTAssertEqual(VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: 82), 82)
        XCTAssertEqual(VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: UInt16.max), nil)
        XCTAssertEqual(VMGuestAgentKeyboard.modifierPressed(forMacVirtualKey: 56, flags: [.shift]), true)
        XCTAssertEqual(VMGuestAgentKeyboard.modifierPressed(forMacVirtualKey: 56, flags: []), false)
        XCTAssertEqual(VMGuestAgentKeyboard.modifierPressed(forMacVirtualKey: 59, flags: [.control]), true)
        XCTAssertNil(VMGuestAgentKeyboard.modifierPressed(forMacVirtualKey: 0, flags: [.shift]))
    }

    func testKeyEquivalentSynthesizesCommandAsLinuxSuperAroundKey() throws {
        XCTAssertEqual(
            VMGuestAgentKeyboard.chordEvents(
                forMacVirtualKey: 40,
                modifierFlags: [.command],
                alreadyPressed: []
            ),
            [
                VMGuestAgentInputEvent(type: 1, code: 125, value: 1),
                VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
                VMGuestAgentInputEvent(type: 1, code: 37, value: 1),
                VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
                VMGuestAgentInputEvent(type: 1, code: 37, value: 0),
                VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
                VMGuestAgentInputEvent(type: 1, code: 125, value: 0),
                VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
            ]
        )
    }

    func testKeyEquivalentDoesNotReleasePhysicallyHeldModifier() throws {
        XCTAssertEqual(
            VMGuestAgentKeyboard.chordEvents(
                forMacVirtualKey: 40,
                modifierFlags: [.command],
                alreadyPressed: [125]
            ),
            [
                VMGuestAgentInputEvent(type: 1, code: 37, value: 1),
                VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
                VMGuestAgentInputEvent(type: 1, code: 37, value: 0),
                VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
            ]
        )
    }

    func testFocusedCommandCaptureForwardsSuperSpaceAndSuppressesHost() {
        var state = VMFocusedCommandCaptureState()
        let commandDown = state.process(.init(
            kind: .flagsChanged, keyCode: 55, modifierFlags: [.command]
        ), focused: true)
        XCTAssertTrue(commandDown.suppressHostEvent)
        XCTAssertEqual(commandDown.guestEvents, keyEvents(125, true))

        let spaceDown = state.process(.init(
            kind: .keyDown, keyCode: 49, modifierFlags: [.command]
        ), focused: true)
        XCTAssertTrue(spaceDown.suppressHostEvent)
        XCTAssertEqual(spaceDown.guestEvents, keyEvents(57, true))

        let spaceUp = state.process(.init(
            kind: .keyUp, keyCode: 49, modifierFlags: [.command]
        ), focused: true)
        XCTAssertTrue(spaceUp.suppressHostEvent)
        XCTAssertEqual(spaceUp.guestEvents, keyEvents(57, false))

        let commandUp = state.process(.init(
            kind: .flagsChanged, keyCode: 55, modifierFlags: []
        ), focused: true)
        XCTAssertTrue(commandUp.suppressHostEvent)
        XCTAssertEqual(commandUp.guestEvents, keyEvents(125, false))
        XCTAssertFalse(state.isCapturing)
    }

    func testFocusedCommandCaptureLeavesUnfocusedShortcutWithMacOS() {
        var state = VMFocusedCommandCaptureState()
        let outcome = state.process(.init(
            kind: .keyDown, keyCode: 49, modifierFlags: [.command]
        ), focused: false)
        XCTAssertFalse(outcome.suppressHostEvent)
        XCTAssertTrue(outcome.guestEvents.isEmpty)
    }

    func testFocusedCommandCaptureRecoversWhenCommandWasAlreadyHeld() {
        var state = VMFocusedCommandCaptureState()
        let outcome = state.process(.init(
            kind: .keyDown, keyCode: 36, modifierFlags: [.command]
        ), focused: true)
        XCTAssertTrue(outcome.suppressHostEvent)
        XCTAssertEqual(
            outcome.guestEvents,
            keyEvents(125, true) + keyEvents(28, true)
        )

        let released = state.process(.init(
            kind: .keyUp, keyCode: 36, modifierFlags: [.command]
        ), focused: false)
        XCTAssertFalse(released.suppressHostEvent)
        XCTAssertEqual(
            released.guestEvents,
            keyEvents(28, false) + keyEvents(125, false)
        )
        XCTAssertFalse(state.isCapturing)
    }

    func testFocusedCommandCaptureBalancesBothCommandKeys() {
        var state = VMFocusedCommandCaptureState()
        XCTAssertEqual(state.process(.init(
            kind: .flagsChanged, keyCode: 55, modifierFlags: [.command]
        ), focused: true).guestEvents, keyEvents(125, true))
        XCTAssertEqual(state.process(.init(
            kind: .flagsChanged, keyCode: 54, modifierFlags: [.command]
        ), focused: true).guestEvents, keyEvents(126, true))
        XCTAssertEqual(state.process(.init(
            kind: .flagsChanged, keyCode: 55, modifierFlags: [.command]
        ), focused: true).guestEvents, keyEvents(125, false))
        XCTAssertEqual(state.process(.init(
            kind: .flagsChanged, keyCode: 54, modifierFlags: []
        ), focused: true).guestEvents, keyEvents(126, false))
        XCTAssertFalse(state.isCapturing)
    }

    func testFocusedCommandCaptureIgnoresRepeatsAndDuplicateReleases() {
        var state = VMFocusedCommandCaptureState()
        _ = state.process(.init(
            kind: .flagsChanged, keyCode: 55, modifierFlags: [.command]
        ), focused: true)
        _ = state.process(.init(
            kind: .keyDown, keyCode: 40, modifierFlags: [.command]
        ), focused: true)
        XCTAssertTrue(state.process(.init(
            kind: .keyDown, keyCode: 40, modifierFlags: [.command], isRepeat: true
        ), focused: true).guestEvents.isEmpty)
        XCTAssertEqual(state.process(.init(
            kind: .keyUp, keyCode: 40, modifierFlags: [.command]
        ), focused: true).guestEvents, keyEvents(37, false))
        XCTAssertTrue(state.process(.init(
            kind: .keyUp, keyCode: 40, modifierFlags: [.command]
        ), focused: true).guestEvents.isEmpty)
    }

    func testFocusedCommandCaptureLetsOtherModifierTransitionsReachAppKit() {
        var state = VMFocusedCommandCaptureState()
        _ = state.process(.init(
            kind: .flagsChanged, keyCode: 55, modifierFlags: [.command]
        ), focused: true)
        let shiftDown = state.process(.init(
            kind: .flagsChanged, keyCode: 56, modifierFlags: [.command, .shift]
        ), focused: true)
        XCTAssertFalse(shiftDown.suppressHostEvent)
        XCTAssertTrue(shiftDown.guestEvents.isEmpty)
    }

    private func keyEvents(_ code: UInt16, _ pressed: Bool) -> [VMGuestAgentInputEvent] {
        VMGuestAgentInputBatch.key(code: code, pressed: pressed).events
    }

    func testAccessibilityKeyDownSynthesizesMissingShiftTransition() throws {
        XCTAssertEqual(
            VMGuestAgentKeyboard.chordEventsForMissingModifierTransition(
                forMacVirtualKey: 0,
                modifierFlags: [.shift],
                alreadyPressed: []
            ),
            [
                VMGuestAgentInputEvent(type: 1, code: 42, value: 1),
                VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
                VMGuestAgentInputEvent(type: 1, code: 30, value: 1),
                VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
                VMGuestAgentInputEvent(type: 1, code: 30, value: 0),
                VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
                VMGuestAgentInputEvent(type: 1, code: 42, value: 0),
                VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
            ]
        )
    }

    func testPhysicalModifierTransitionIsNotSynthesizedTwice() {
        XCTAssertNil(
            VMGuestAgentKeyboard.chordEventsForMissingModifierTransition(
                forMacVirtualKey: 0,
                modifierFlags: [.shift],
                alreadyPressed: [42]
            )
        )
        XCTAssertNil(
            VMGuestAgentKeyboard.chordEventsForMissingModifierTransition(
                forMacVirtualKey: 0,
                modifierFlags: [],
                alreadyPressed: []
            )
        )
    }

    func testAccessibilityTextInfersMissingShiftForUppercaseAndSymbols() {
        XCTAssertTrue(VMGuestAgentKeyboard.effectiveModifierFlags(
            reported: [], characters: "!", charactersIgnoringModifiers: "1"
        ).contains(.shift))
        XCTAssertTrue(VMGuestAgentKeyboard.effectiveModifierFlags(
            reported: [], characters: "E", charactersIgnoringModifiers: "e"
        ).contains(.shift))
        XCTAssertFalse(VMGuestAgentKeyboard.effectiveModifierFlags(
            reported: [], characters: "e", charactersIgnoringModifiers: "e"
        ).contains(.shift))
    }

    func testDesktopInputRequiresHyprlandToOwnTheGuestKeyboard() {
        let console = VMGuestAgentStatus(
            agentVersion: "1", operatingSystem: "Linux", kernelVersion: "7",
            hostName: "guest", addresses: [], bootID: "boot", uptimeSeconds: 1,
            capabilities: ["input-uinput-v1", "input-uinput-absolute-v1"],
            inputDevices: ["hyprctl devices unavailable: Hyprland process not found"]
        )
        XCTAssertTrue(console.supportsGuestInput)
        XCTAssertFalse(console.supportsDesktopGuestInput)
        XCTAssertTrue(console.shouldUseGuestKeyboard)

        let unverifiedDesktop = VMGuestAgentStatus(
            agentVersion: "1", operatingSystem: "Linux", kernelVersion: "7",
            hostName: "guest", addresses: [], bootID: "boot", uptimeSeconds: 1,
            capabilities: ["input-uinput-v1", "input-uinput-absolute-v1"],
            inputDevices: ["hyprctl devices failed"], desktopSessionActive: true
        )
        XCTAssertFalse(unverifiedDesktop.supportsDesktopGuestInput)
        XCTAssertFalse(unverifiedDesktop.shouldUseGuestKeyboard)

        let compositorOwnsKeyboard = VMGuestAgentStatus(
            agentVersion: "1", operatingSystem: "Linux", kernelVersion: "7",
            hostName: "guest", addresses: [], bootID: "boot", uptimeSeconds: 2,
            capabilities: ["input-uinput-v1", "input-uinput-absolute-v1"],
            inputDevices: [
                "hyprctl devices failed: stale compositor socket",
                "EZVM Keyboard [sysrq kbd event3]",
                "Hyprland open input devices [event0 event1 event3 event6]",
            ],
            desktopSessionActive: true
        )
        XCTAssertTrue(compositorOwnsKeyboard.supportsDesktopGuestInput)
        XCTAssertTrue(compositorOwnsKeyboard.shouldUseGuestKeyboard)

        let compositorDoesNotOwnKeyboard = VMGuestAgentStatus(
            agentVersion: "1", operatingSystem: "Linux", kernelVersion: "7",
            hostName: "guest", addresses: [], bootID: "boot", uptimeSeconds: 2,
            capabilities: ["input-uinput-v1", "input-uinput-absolute-v1"],
            inputDevices: [
                "EZVM Keyboard [sysrq kbd event3]",
                "Hyprland open input devices [event0 event1 event2]",
            ],
            desktopSessionActive: true
        )
        XCTAssertFalse(compositorDoesNotOwnKeyboard.supportsDesktopGuestInput)
        XCTAssertFalse(compositorDoesNotOwnKeyboard.shouldUseGuestKeyboard)

        let legacyDesktop = VMGuestAgentStatus(
            agentVersion: "1", operatingSystem: "Linux", kernelVersion: "7",
            hostName: "guest", addresses: [], bootID: "boot", uptimeSeconds: 2,
            capabilities: ["input-uinput-v1", "input-uinput-absolute-v1"],
            inputDevices: ["hyprctl EZVM Keyboard: keyboards: EZVM Keyboard"]
        )
        XCTAssertTrue(legacyDesktop.supportsDesktopGuestInput)
        XCTAssertTrue(legacyDesktop.shouldUseGuestKeyboard)

        let currentDesktop = VMGuestAgentStatus(
            agentVersion: "2", operatingSystem: "Linux", kernelVersion: "7",
            hostName: "guest", addresses: [], bootID: "boot", uptimeSeconds: 3,
            capabilities: ["input-uinput-v1", "input-uinput-desktop-v1"],
            inputDevices: nil
        )
        XCTAssertTrue(currentDesktop.supportsDesktopGuestInput)
        XCTAssertTrue(currentDesktop.shouldUseGuestKeyboard)
    }

    func testDynamicDisplayWaitsForDesktopAndCompletedProvisioning() {
        func status(desktop: Bool?, provisioning: Bool?) -> VMGuestAgentStatus {
            VMGuestAgentStatus(
                agentVersion: "2", operatingSystem: "Linux", kernelVersion: "7",
                hostName: "guest", addresses: [], bootID: "boot", uptimeSeconds: 1,
                capabilities: [], desktopSessionActive: desktop,
                provisioningPending: provisioning
            )
        }

        XCTAssertFalse(status(desktop: false, provisioning: false).allowsDynamicDisplay)
        XCTAssertFalse(status(desktop: true, provisioning: true).allowsDynamicDisplay)
        XCTAssertTrue(status(desktop: true, provisioning: false).allowsDynamicDisplay)
        XCTAssertTrue(status(desktop: true, provisioning: nil).allowsDynamicDisplay)
    }

    func testMutualAuthenticationRoundTrip() throws {
        let guest = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let host = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let hello = try guest.makeHello(guestNonce: guestNonce)
        try host.verifyHello(hello)
        let welcome = try host.makeWelcome(guestNonce: guestNonce, hostNonce: hostNonce)
        try guest.verifyWelcome(welcome, guestNonce: guestNonce)
    }

    func testWrongTokenAndMachineCannotAuthenticate() throws {
        let guest = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let hello = try guest.makeHello(guestNonce: guestNonce)
        let wrongToken = try VMGuestAgentAuthenticator(tokenData: Data(repeating: 7, count: 32), machineID: machineID)
        XCTAssertThrowsError(try wrongToken.verifyHello(hello)) { XCTAssertEqual($0 as? VMGuestAgentAuthenticationError, .invalidProof) }
        let wrongMachine = try VMGuestAgentAuthenticator(tokenData: token, machineID: "machine-b")
        XCTAssertThrowsError(try wrongMachine.verifyHello(hello)) { XCTAssertEqual($0 as? VMGuestAgentAuthenticationError, .invalidMachine) }
    }

    func testInvalidVersionAndNonceAreRejected() throws {
        let authenticator = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let valid = try authenticator.makeHello(guestNonce: guestNonce)
        let future = VMGuestAgentHello(version: 99, machineID: valid.machineID, guestNonce: valid.guestNonce, proof: valid.proof)
        XCTAssertThrowsError(try authenticator.verifyHello(future))
        XCTAssertThrowsError(try authenticator.makeHello(guestNonce: Data("short".utf8).base64EncodedString()))
        XCTAssertThrowsError(try VMGuestAgentAuthenticator(tokenData: Data(), machineID: machineID))
    }

    func testEnvelopeIntegrityAndReplayProtection() throws {
        let sender = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        var receiver = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let sessionID = try sender.sessionID(guestNonce: guestNonce, hostNonce: hostNonce)
        let payload = try JSONEncoder().encode(VMGuestAgentStatus(
            agentVersion: "1.0", operatingSystem: "Alpine Linux", kernelVersion: "6.12",
            hostName: "ezvm", addresses: ["192.168.64.2"], bootID: "boot-a", uptimeSeconds: 12,
            capabilities: [
                "file-transfer-v1", "ssh-addresses-v1", "input-uinput-v1",
                "input-uinput-absolute-v1",
            ]
        ))
        let envelope = try sender.makeEnvelope(sessionID: sessionID, sequence: 1, requestID: "request-1", operation: .status, payload: payload)
        try receiver.verifyEnvelope(envelope, sessionID: sessionID)
        XCTAssertThrowsError(try receiver.verifyEnvelope(envelope, sessionID: sessionID)) { XCTAssertEqual($0 as? VMGuestAgentAuthenticationError, .replayedSequence) }

        var fresh = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let changed = VMGuestAgentEnvelope(
            version: envelope.version, sessionID: envelope.sessionID, sequence: envelope.sequence, requestID: envelope.requestID,
            operation: .shutdown, payload: envelope.payload, proof: envelope.proof
        )
        XCTAssertThrowsError(try fresh.verifyEnvelope(changed, sessionID: sessionID)) { XCTAssertEqual($0 as? VMGuestAgentAuthenticationError, .invalidProof) }

        var reconnected = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let nextSession = try sender.sessionID(
            guestNonce: Data(repeating: 0x33, count: 32).base64EncodedString(), hostNonce: hostNonce
        )
        XCTAssertThrowsError(try reconnected.verifyEnvelope(envelope, sessionID: nextSession)) {
            XCTAssertEqual($0 as? VMGuestAgentAuthenticationError, .invalidProof)
        }
    }

    func testLengthPrefixedFrameRoundTripAndLimits() throws {
        let hello = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID).makeHello(guestNonce: guestNonce)
        let frame = try VMGuestAgentFrameCodec.encode(hello)
        XCTAssertEqual(try VMGuestAgentFrameCodec.decode(VMGuestAgentHello.self, from: frame), hello)
        XCTAssertThrowsError(try VMGuestAgentFrameCodec.decode(VMGuestAgentHello.self, from: frame.dropLast()))

        let oversized = Data(repeating: 0, count: VMGuestAgentProtocol.maximumFrameBytes + 1)
        XCTAssertThrowsError(try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
            .makeEnvelope(sessionID: "session", sequence: 1, requestID: "large", operation: .status, payload: oversized))
    }

    func testStatusPayloadRoundTrips() throws {
        let status = VMGuestAgentStatus(
            agentVersion: "1.2.3", agentInstanceID: "instance-a",
            operatingSystem: "Ubuntu 26.04", kernelVersion: "7.0",
            hostName: "builder", addresses: ["10.0.2.15", "fd00::15"], bootID: "abc", uptimeSeconds: 99,
            capabilities: [
                "file-transfer-v1", "ssh-addresses-v1", "input-uinput-v1",
                "input-uinput-absolute-v1",
            ]
        )
        XCTAssertEqual(try JSONDecoder().decode(VMGuestAgentStatus.self, from: JSONEncoder().encode(status)), status)
        XCTAssertEqual(status.agentInstanceID, "instance-a")
        XCTAssertTrue(status.supportsAbsoluteGuestPointer)
        XCTAssertTrue(status.hasIPv4Address)
        XCTAssertEqual(Set(VMGuestAgentOperation.allCases), [
            .heartbeat, .status, .shutdown, .restart, .restartAgent,
            .uploadStart, .uploadChunk, .uploadCommit, .transferCancel,
            .downloadInfo, .downloadChunk, .input, .ownerProvisioning,
            .clipboardSet, .clipboardGet,
        ])

        let clipboardRequest = VMOmarchyClipboardRequest(
            relativePath: ".ezvm-clipboard-01234567-89ab-cdef-0123-456789abcdef.txt",
            mimeType: "text/plain;charset=utf-8",
            byteCount: 12,
            sha256: String(repeating: "a", count: 64)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                VMOmarchyClipboardRequest.self,
                from: JSONEncoder().encode(clipboardRequest)
            ),
            clipboardRequest
        )

        let legacyJSON = Data(#"{"agentVersion":"1.0","operatingSystem":"Linux","kernelVersion":"6","hostName":"legacy","addresses":[],"bootID":"old","uptimeSeconds":1}"#.utf8)
        let legacy = try JSONDecoder().decode(VMGuestAgentStatus.self, from: legacyJSON)
        XCTAssertNil(legacy.capabilities)
        XCTAssertNil(legacy.agentInstanceID)
        XCTAssertFalse(legacy.supportsSSH)
        XCTAssertFalse(legacy.supportsFileTransfer)
        XCTAssertFalse(legacy.supportsGuestInput)
        XCTAssertFalse(legacy.supportsDesktopGuestInput)
        XCTAssertFalse(legacy.hasIPv4Address)
        XCTAssertTrue(status.supportsSSH)
        XCTAssertTrue(status.supportsFileTransfer)
        XCTAssertTrue(status.supportsGuestInput)
    }

    func testOwnerProvisioningRequestRoundTripsWithoutDuplicatePassword() throws {
        let request = VMOmarchyOwnerProvisioningRequest(
            username: "omarchy",
            password: "temporary-password",
            keyboard: "us",
            fullName: "Omarchy Owner",
            emailAddress: "owner@example.com",
            hostname: "omarchy",
            timezone: "America/Los_Angeles"
        )
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(VMOmarchyOwnerProvisioningRequest.self, from: data), request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["password"] as? String, "temporary-password")
        XCTAssertNil(object["passwordConfirmation"])
    }

    func testGuestIPv4EvidenceRejectsIPv6AndMalformedAddresses() {
        let status = VMGuestAgentStatus(
            agentVersion: "1", operatingSystem: "Linux", kernelVersion: "7",
            hostName: "guest", addresses: ["fd00::15", "not-an-address", "10.0.0.1.example"],
            bootID: "boot", uptimeSeconds: 1, capabilities: nil
        )
        XCTAssertFalse(status.hasIPv4Address)
    }

    func testFrameBufferHandlesPartialAndCoalescedReads() throws {
        let auth = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let first = try VMGuestAgentFrameCodec.encode(auth.makeHello(guestNonce: guestNonce))
        let second = try VMGuestAgentFrameCodec.encode(auth.makeWelcome(guestNonce: guestNonce, hostNonce: hostNonce))
        var buffer = VMGuestAgentFrameBuffer()
        XCTAssertTrue(try buffer.append(first.prefix(3)).isEmpty)
        XCTAssertEqual(try buffer.append(first.dropFirst(3) + second).count, 2)
        XCTAssertTrue(buffer.data.isEmpty)
    }

    func testFrameBufferRejectsAdvertisedOversizedFrameBeforePayloadArrives() throws {
        var length = UInt32(VMGuestAgentProtocol.maximumFrameBytes + 1).bigEndian
        let header = Data(bytes: &length, count: 4)
        var buffer = VMGuestAgentFrameBuffer()
        XCTAssertThrowsError(try buffer.append(header)) {
            XCTAssertEqual($0 as? VMGuestAgentAuthenticationError, .oversizedFrame)
        }
    }

    func testProtocolMatchesPublishedCrossLanguageVectors() throws {
        let authenticator = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        XCTAssertEqual(
            try authenticator.makeHello(guestNonce: guestNonce).proof,
            "Q2bgyj5cc0VI41gARg64PlS3qA7/poair6kJ5ISyz30="
        )
        XCTAssertEqual(
            try authenticator.makeWelcome(guestNonce: guestNonce, hostNonce: hostNonce).proof,
            "TK3n9Y+ST9leXS55GQaolfhS9ElcRZDY2OHuPvqXndo="
        )
        XCTAssertEqual(
            try authenticator.makeEnvelope(
                sessionID: "session-a", sequence: 7, requestID: "request-7",
                operation: .status, payload: Data("payload".utf8)
            ).proof,
            "OtNjPmizYoCykrwAy2LUpE2yLnzThrxYkdHq77yVfi4="
        )
    }

    func testLivenessExpiresOnlyAfterResponseTimeoutAndResets() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var liveness = VMGuestAgentLiveness()
        XCTAssertFalse(liveness.hasExpired(at: start.addingTimeInterval(100)))
        liveness.markResponse(at: start)
        XCTAssertFalse(liveness.hasExpired(at: start.addingTimeInterval(30)))
        XCTAssertTrue(liveness.hasExpired(at: start.addingTimeInterval(30.001)))
        liveness.reset()
        XCTAssertFalse(liveness.hasExpired(at: start.addingTimeInterval(100)))
    }

    func testFileTransferPayloadsRoundTripAndValidateBoundaries() throws {
        let transferID = UUID().uuidString
        let start = VMGuestAgentUploadStart(
            transferID: transferID, destinationPath: "/tmp/report.txt", totalBytes: 7,
            sha256: String(repeating: "a", count: 64), overwrite: false
        )
        try VMGuestAgentTransferValidator.validate(transferID: start.transferID)
        try VMGuestAgentTransferValidator.validate(path: start.destinationPath)
        try VMGuestAgentTransferValidator.validate(totalBytes: start.totalBytes, sha256: start.sha256)
        XCTAssertEqual(try JSONDecoder().decode(VMGuestAgentUploadStart.self, from: JSONEncoder().encode(start)), start)

        let chunk = VMGuestAgentUploadChunk(transferID: transferID, offset: 0, data: Data("payload".utf8))
        try VMGuestAgentTransferValidator.validate(offset: chunk.offset, data: chunk.data)
        XCTAssertEqual(try JSONDecoder().decode(VMGuestAgentUploadChunk.self, from: JSONEncoder().encode(chunk)), chunk)

        XCTAssertThrowsError(try VMGuestAgentTransferValidator.validate(transferID: "not-a-uuid"))
        XCTAssertThrowsError(try VMGuestAgentTransferValidator.validate(path: "relative/path"))
        XCTAssertThrowsError(try VMGuestAgentTransferValidator.validate(path: "/tmp/invalid\0path"))
        XCTAssertThrowsError(try VMGuestAgentTransferValidator.validate(totalBytes: 1, sha256: "short"))
        XCTAssertThrowsError(try VMGuestAgentTransferValidator.validate(
            totalBytes: VMGuestAgentProtocol.maximumTransferBytes + 1,
            sha256: String(repeating: "f", count: 64)
        ))
        XCTAssertThrowsError(try VMGuestAgentTransferValidator.validate(
            offset: 0, data: Data(repeating: 0, count: VMGuestAgentProtocol.fileChunkBytes + 1)
        ))
    }

    func testSSHURLAcceptsIPv4AndIPv6WithoutShellInterpolation() {
        XCTAssertEqual(VMGuestAgentSSH.url(username: "builder", address: "192.168.64.2")?.absoluteString, "ssh://builder@192.168.64.2")
        XCTAssertEqual(VMGuestAgentSSH.url(username: "user_1", address: "fd00::15")?.absoluteString, "ssh://user_1@[fd00::15]")
        XCTAssertNil(VMGuestAgentSSH.url(username: "bad user", address: "192.168.64.2"))
        XCTAssertNil(VMGuestAgentSSH.url(username: "root;open", address: "192.168.64.2"))
        XCTAssertNil(VMGuestAgentSSH.url(username: "root", address: "example.com"))
        XCTAssertNil(VMGuestAgentSSH.url(username: "root", address: "fe80::1%en0"))
    }

    func testLocalFileMetadataStreamsChecksumAndRejectsSymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.bin")
        let content = Data(repeating: 0x5a, count: VMGuestAgentProtocol.fileChunkBytes + 37)
        try content.write(to: file)
        let metadata = try VMGuestAgentLocalFile.metadata(at: file)
        XCTAssertEqual(metadata.size, UInt64(content.count))
        XCTAssertEqual(metadata.sha256, Data(SHA256.hash(data: content)).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try VMGuestAgentLocalFile.readChunk(at: file, offset: 0).count, VMGuestAgentProtocol.fileChunkBytes)
        XCTAssertEqual(try VMGuestAgentLocalFile.readChunk(at: file, offset: UInt64(VMGuestAgentProtocol.fileChunkBytes)).count, 37)

        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try VMGuestAgentLocalFile.metadata(at: link))
    }

    func testDownloadTransactionCommitsAtomicallyAndPreservesDestinationOnFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("download.bin")
        try Data("original".utf8).write(to: destination)
        let content = Data(repeating: 0x31, count: VMGuestAgentProtocol.fileChunkBytes + 9)
        let checksum = Data(SHA256.hash(data: content)).map { String(format: "%02x", $0) }.joined()

        let transaction = try VMGuestAgentDownloadTransaction(
            destination: destination, totalBytes: UInt64(content.count), expectedSHA256: checksum
        )
        try transaction.append(offset: 0, data: content.prefix(VMGuestAgentProtocol.fileChunkBytes))
        XCTAssertThrowsError(try transaction.append(offset: 1, data: Data()))
        try transaction.append(
            offset: UInt64(VMGuestAgentProtocol.fileChunkBytes),
            data: content.dropFirst(VMGuestAgentProtocol.fileChunkBytes)
        )
        try transaction.commit()
        XCTAssertEqual(try Data(contentsOf: destination), content)

        try Data("keep-me".utf8).write(to: destination)
        let failed = try VMGuestAgentDownloadTransaction(
            destination: destination, totalBytes: 1, expectedSHA256: String(repeating: "0", count: 64)
        )
        try failed.append(offset: 0, data: Data([1]))
        XCTAssertThrowsError(try failed.commit())
        failed.cancel()
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep-me".utf8))
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: directory.path)).allSatisfy { !$0.hasPrefix(".ezvm-download-") })
    }
}
