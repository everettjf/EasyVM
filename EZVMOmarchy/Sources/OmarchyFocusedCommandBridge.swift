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
                guard let self, self.tap == nil else { return }
                self.installEventTap()
            }
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
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        if AXIsProcessTrusted() {
            start()
            return
        }
        NSWorkspace.shared.open(Self.accessibilitySettingsURL)
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
        guard tap != nil, AXIsProcessTrusted(), focusProbe() else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false) else {
            return false
        }
        for event in [keyDown, keyUp] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: Self.acceptanceMarker)
            event.post(tap: .cghidEventTap)
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
