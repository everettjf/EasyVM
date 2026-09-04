import AppKit
import CoreGraphics

enum OmarchyKeyboardIntegrationState: Equatable {
    case enabled
    case accessibilityRequired
}

enum OmarchyCommandCapturePolicy {
    static func shouldRedirect(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        focused: Bool,
        isSynthetic: Bool
    ) -> Bool {
        guard focused, !isSynthetic, flags.contains(.maskCommand) else { return false }
        guard type == .keyDown || type == .keyUp else { return false }
        // Modifier-only transitions continue through the normal VZ input path.
        return keyCode != 54 && keyCode != 55
    }
}

struct OmarchyCommandSpaceCaptureState {
    private(set) var sawKeyDown = false

    mutating func observe(type: CGEventType, keyCode: CGKeyCode) -> Bool {
        guard keyCode == 49 else { return false }
        if type == .keyDown {
            sawKeyDown = true
            return false
        }
        guard type == .keyUp, sawKeyDown else { return false }
        sawKeyDown = false
        return true
    }
}

struct OmarchyAcceptanceKeyTransition: Equatable {
    let keyCode: CGKeyCode
    let keyDown: Bool
    let flags: CGEventFlags
}

enum OmarchyAcceptanceKeySequence {
    static func chord(
        keyCode: CGKeyCode,
        additionalFlags: CGEventFlags
    ) -> [OmarchyAcceptanceKeyTransition] {
        var heldFlags: CGEventFlags = .maskCommand
        var transitions = [
            OmarchyAcceptanceKeyTransition(
                keyCode: 55,
                keyDown: true,
                flags: heldFlags
            ),
        ]
        if additionalFlags.contains(.maskControl) {
            heldFlags.insert(.maskControl)
            transitions.append(.init(keyCode: 59, keyDown: true, flags: heldFlags))
        }
        if additionalFlags.contains(.maskAlternate) {
            heldFlags.insert(.maskAlternate)
            transitions.append(.init(keyCode: 58, keyDown: true, flags: heldFlags))
        }
        if additionalFlags.contains(.maskShift) {
            heldFlags.insert(.maskShift)
            transitions.append(.init(keyCode: 56, keyDown: true, flags: heldFlags))
        }
        transitions.append(.init(keyCode: keyCode, keyDown: true, flags: heldFlags))
        transitions.append(.init(keyCode: keyCode, keyDown: false, flags: heldFlags))
        if additionalFlags.contains(.maskShift) {
            heldFlags.remove(.maskShift)
            transitions.append(.init(keyCode: 56, keyDown: false, flags: heldFlags))
        }
        if additionalFlags.contains(.maskAlternate) {
            heldFlags.remove(.maskAlternate)
            transitions.append(.init(keyCode: 58, keyDown: false, flags: heldFlags))
        }
        if additionalFlags.contains(.maskControl) {
            heldFlags.remove(.maskControl)
            transitions.append(.init(keyCode: 59, keyDown: false, flags: heldFlags))
        }
        transitions.append(.init(keyCode: 55, keyDown: false, flags: []))
        return transitions
    }
}

final class OmarchyFocusedCommandBridge {
    private static let syntheticMarker: Int64 = 0x455A_4F4D_4152_4348
    private static let acceptanceMarker: Int64 = 0x455A_4143_4345_5054

    private let focusProbe: () -> Bool
    private let stateChanged: (OmarchyKeyboardIntegrationState) -> Void
    private let commandSpaceCaptured: () -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var commandSpaceState = OmarchyCommandSpaceCaptureState()

    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        guard AXIsProcessTrusted() else {
            NSWorkspace.shared.open(accessibilitySettingsURL)
            return false
        }
        return true
    }

    init(
        focusProbe: @escaping () -> Bool,
        stateChanged: @escaping (OmarchyKeyboardIntegrationState) -> Void,
        commandSpaceCaptured: @escaping () -> Void = {}
    ) {
        self.focusProbe = focusProbe
        self.stateChanged = stateChanged
        self.commandSpaceCaptured = commandSpaceCaptured
    }

    func start() {
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.start()
            }
        }
        guard AXIsProcessTrusted() else {
            stateChanged(.accessibilityRequired)
            return
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            stateChanged(.enabled)
            return
        }
        installEventTap()
    }

    private func installEventTap() {
        guard tap == nil else { return }
        let mask = (UInt64(1) << CGEventType.keyDown.rawValue)
            | (UInt64(1) << CGEventType.keyUp.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let bridge = Unmanaged<OmarchyFocusedCommandBridge>
                    .fromOpaque(userInfo).takeUnretainedValue()
                return bridge.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            stateChanged(.accessibilityRequired)
            return
        }
        tap = eventTap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        stateChanged(.enabled)
    }

    func requestPermission() {
        if Self.requestAccessibilityAccess() {
            start()
            return
        }
        permissionTimer?.invalidate()
        var attemptsRemaining = 40
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.permissionTimer = nil
                self.start()
                return
            }
            attemptsRemaining -= 1
            if attemptsRemaining == 0 {
                timer.invalidate()
                self.permissionTimer = nil
                self.stateChanged(.accessibilityRequired)
            }
        }
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
    }

    @discardableResult
    func runAcceptanceCommandSpaceProbe() -> Bool {
        runAcceptanceCommandChordProbe(keyCode: 49)
    }

    @discardableResult
    func runAcceptanceCommandChordProbe(
        keyCode: CGKeyCode,
        additionalFlags: CGEventFlags = []
    ) -> Bool {
        guard tap != nil, AXIsProcessTrusted(), focusProbe() else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let transitions = OmarchyAcceptanceKeySequence.chord(
            keyCode: keyCode,
            additionalFlags: additionalFlags
        )
        var events: [CGEvent] = []
        for transition in transitions {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: transition.keyCode,
                keyDown: transition.keyDown
            ) else { return false }
            event.flags = transition.flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.acceptanceMarker)
            events.append(event)
        }
        // VZ's virtual USB keyboard consumes physical modifier transitions; a
        // key carrying modifier flags alone is not equivalent to a real chord.
        // Pace the balanced sequence so every transition reaches AppKit/VZ.
        for (index, event) in events.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.03) {
                event.post(tap: .cghidEventTap)
            }
        }
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let synthetic = event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let redirect = OmarchyCommandCapturePolicy.shouldRedirect(
            type: type,
            keyCode: keyCode,
            flags: event.flags,
            focused: focusProbe(),
            isSynthetic: synthetic
        )
        guard redirect, let localEvent = event.copy() else {
            return Unmanaged.passUnretained(event)
        }
        if commandSpaceState.observe(type: type, keyCode: keyCode) {
            DispatchQueue.main.async { [commandSpaceCaptured] in commandSpaceCaptured() }
        }
        localEvent.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        localEvent.postToPid(ProcessInfo.processInfo.processIdentifier)
        return nil
    }
}
