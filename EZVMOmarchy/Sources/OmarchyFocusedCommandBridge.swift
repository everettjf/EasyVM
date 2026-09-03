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

final class OmarchyFocusedCommandBridge {
    private static let syntheticMarker: Int64 = 0x455A_4F4D_4152_4348

    private let focusProbe: () -> Bool
    private let stateChanged: (OmarchyKeyboardIntegrationState) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var permissionTimer: Timer?

    init(
        focusProbe: @escaping () -> Bool,
        stateChanged: @escaping (OmarchyKeyboardIntegrationState) -> Void
    ) {
        self.focusProbe = focusProbe
        self.stateChanged = stateChanged
    }

    func start() {
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
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let synthetic = event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker
        let redirect = OmarchyCommandCapturePolicy.shouldRedirect(
            type: type,
            keyCode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags,
            focused: focusProbe(),
            isSynthetic: synthetic
        )
        guard redirect, let localEvent = event.copy() else {
            return Unmanaged.passUnretained(event)
        }
        localEvent.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        localEvent.postToPid(ProcessInfo.processInfo.processIdentifier)
        return nil
    }
}
