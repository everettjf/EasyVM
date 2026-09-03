//
//  VMModelFieldGraphicDevice.swift
//  EZVM
//
//  Created by everettjf on 2022/8/24.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Metal
import QuartzCore
import Virtualization
#if arch(arm64)
import EZVMVirGLRuntime
#endif

#if arch(arm64)
struct VMModelFieldGraphicDevice : Decodable, Encodable, CustomStringConvertible {
    enum DeviceType : String, CaseIterable, Identifiable, Decodable, Encodable {
        case Mac, Virtio
        var id: Self { self }

        var displayName: String {
            switch self {
            case .Mac: "Mac Display"
            case .Virtio: "Virtio Display"
            }
        }
    }
    
    let type: DeviceType
    let width: Int
    let height: Int
    let pixelsPerInch: Int
    
    var description: String {
        if type == .Virtio {
            return "\(type.displayName) · \(width) × \(height)"
        } else {
            return "\(type.displayName) · \(width) × \(height) · \(pixelsPerInch) ppi"
        }
    }
    
    static func `default`(osType: VMOSType) -> VMModelFieldGraphicDevice {
        switch osType {
        case .macOS:
            return VMModelFieldGraphicDevice(type: .Mac, width: 1920, height: 1200, pixelsPerInch: 80)
        case .linux:
            return VMModelFieldGraphicDevice(type: .Virtio, width: 1280, height: 720, pixelsPerInch: 0)
        }
    }
    
    func createConfiguration() -> VZGraphicsDeviceConfiguration {
        if self.type == .Virtio {
            let config = VZVirtioGraphicsDeviceConfiguration()
            config.scanouts = [
                VZVirtioGraphicsScanoutConfiguration(widthInPixels: self.width, heightInPixels: self.height)
            ]
            return config
        }
        
        let graphicsConfiguration = VZMacGraphicsDeviceConfiguration()
        graphicsConfiguration.displays = [
            // We abitrarily choose the resolution of the display to be 1920 x 1200.
            VZMacGraphicsDisplayConfiguration(widthInPixels: self.width, heightInPixels: self.height, pixelsPerInch: self.pixelsPerInch)
        ]
        return graphicsConfiguration
    }
}

protocol VMGraphicsBackend {
    var kind: VMGraphicsBackendKind { get }
    var displayView: NSView { get }
    var supportsMachineSaveRestore: Bool { get }
    func applyGraphics(
        from devices: [VMModelFieldGraphicDevice],
        to configuration: VZVirtualMachineConfiguration
    ) -> VMOSResultVoid
    func bind(virtualMachine: VZVirtualMachine?)
    func refreshDisplayConfiguration()
    func setDynamicDisplayReady(_ ready: Bool)
    func setGuestInputHandler(_ handler: (([VMGuestAgentInputEvent]) -> Void)?)
    func setKeyboardIntegrationStateHandler(_ handler: ((VMKeyboardIntegrationState) -> Void)?)
    func requestKeyboardIntegrationPermission()
    func setAbsolutePointerEnabled(_ enabled: Bool)
    func setRuntimeIssueHandler(_ handler: ((String?) -> Void)?)
    func shutdown()
}

final class VMAppleGraphicsBackend: VMGraphicsBackend {
    let kind = VMGraphicsBackendKind.appleVirtio
    let supportsMachineSaveRestore = true
    let virtualMachineView: VZVirtualMachineView
    var displayView: NSView { virtualMachineView }

    init() {
        virtualMachineView = VZVirtualMachineView()
        if #available(macOS 14.0, *) {
            virtualMachineView.automaticallyReconfiguresDisplay = true
        }
    }

    func applyGraphics(
        from devices: [VMModelFieldGraphicDevice],
        to configuration: VZVirtualMachineConfiguration
    ) -> VMOSResultVoid {
        configuration.graphicsDevices = devices.map { $0.createConfiguration() }
        return .success
    }

    func bind(virtualMachine: VZVirtualMachine?) {
        virtualMachineView.virtualMachine = virtualMachine
    }

    func refreshDisplayConfiguration() {
        guard #available(macOS 14.0, *) else { return }
        virtualMachineView.automaticallyReconfiguresDisplay = false
        virtualMachineView.automaticallyReconfiguresDisplay = true
    }

    func setDynamicDisplayReady(_ ready: Bool) {}

    func setGuestInputHandler(_ handler: (([VMGuestAgentInputEvent]) -> Void)?) {}

    func setKeyboardIntegrationStateHandler(_ handler: ((VMKeyboardIntegrationState) -> Void)?) {
        handler?(.unavailable)
    }

    func requestKeyboardIntegrationPermission() {}

    func setAbsolutePointerEnabled(_ enabled: Bool) {}

    func setRuntimeIssueHandler(_ handler: ((String?) -> Void)?) {}

    func shutdown() {
        virtualMachineView.virtualMachine = nil
    }
}

@available(macOS 27.0, *)
private final class VMFocusedCommandEventTap {
    typealias FocusProbe = () -> Bool
    typealias EventHandler = ([VMGuestAgentInputEvent]) -> Void

    private let focusProbe: FocusProbe
    private let eventHandler: EventHandler
    private var state = VMFocusedCommandCaptureState()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var focusTimer: Timer?

    init(focusProbe: @escaping FocusProbe, eventHandler: @escaping EventHandler) {
        self.focusProbe = focusProbe
        self.eventHandler = eventHandler
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (UInt64(1) << CGEventType.keyDown.rawValue)
            | (UInt64(1) << CGEventType.keyUp.rawValue)
            | (UInt64(1) << CGEventType.flagsChanged.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<VMFocusedCommandEventTap>
                    .fromOpaque(userInfo).takeUnretainedValue()
                return owner.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        tap = eventTap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.releaseIfFocusWasLost()
        }
        return true
    }

    func stop() {
        emit(state.releaseAll())
        focusTimer?.invalidate()
        focusTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            emit(state.releaseAll())
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let kind: VMFocusedCommandEventKind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        default: return Unmanaged.passUnretained(event)
        }
        let input = VMFocusedCommandEvent(
            kind: kind,
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)),
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
        let outcome = state.process(input, focused: focusProbe())
        emit(outcome.guestEvents)
        return outcome.suppressHostEvent ? nil : Unmanaged.passUnretained(event)
    }

    private func releaseIfFocusWasLost() {
        guard state.isCapturing, !focusProbe() else { return }
        emit(state.releaseAll())
    }

    private func emit(_ events: [VMGuestAgentInputEvent]) {
        guard !events.isEmpty else { return }
        // Each transition is a key event followed by SYN_REPORT. Split large
        // forced releases without breaking those pairs or the Agent's 64-event
        // input-batch limit.
        let maximumPairs = VMGuestAgentInputBatch.maximumEventCount / 2
        var pairIndex = 0
        while pairIndex * 2 < events.count {
            let start = pairIndex * 2
            let end = min(events.count, start + maximumPairs * 2)
            eventHandler(Array(events[start..<end]))
            pairIndex += maximumPairs
        }
    }
}

@available(macOS 27.0, *)
final class VMVirGLDisplayView: VZVirtualMachineView {
    private let backgroundLayer = CALayer()
    private let metalLayer = CAMetalLayer()
    private let cursorLayer = CALayer()
    weak var runtime: EZVMVirGLRuntime?
    private var guestInputHandler: (([VMGuestAgentInputEvent]) -> Void)?
    var runtimeIssueHandler: ((String?) -> Void)?
    private var presentedFrames: UInt64 = 0
    private var performanceWindowStartedAt = CACurrentMediaTime()
    private var requestedFramesInWindow: UInt64 = 0
    private var presentedFramesInWindow: UInt64 = 0
    private var drawableMissesInWindow: UInt64 = 0
    private var failuresInWindow: UInt64 = 0
    private var totalPresentationTimeInWindow: TimeInterval = 0
    private var maximumPresentationTimeInWindow: TimeInterval = 0
    private var presentationDurationsInWindow: [TimeInterval] = []
    private var cursorPosition = CGPoint.zero
    private var cursorHotspot = CGPoint.zero
    private var cursorImageSize = CGSize.zero
    private var pressedKeys = Set<UInt16>()
    private var pressedButtons = Set<UInt16>()
    private var pointerCaptured = false
    private var windowObservers: [NSObjectProtocol] = []
    private var commandKeyMonitor: Any?
    private var focusedCommandEventTap: VMFocusedCommandEventTap?
    private var accessibilityRetryTimer: Timer?
    private var keyboardIntegrationStateHandler: ((VMKeyboardIntegrationState) -> Void)?
    private var guestSize: CGSize
    private var scrollWheelAccumulator = VMScrollWheelAccumulator()
    private var latestScanout: (resourceID: UInt32, x: Int, y: Int, width: Int, height: Int)?
    private var displayRefreshTimer: Timer?
    private var presentationInFlight = false
    private var presentationHealth = VMGraphicsPresentationHealthTracker()
    private var presentationLifecycle = VMGraphicsPresentationLifecycle()
    private var presentationEventFence = VMGraphicsPresentationEventFence()
    // Input falls back to Virtualization.framework until the authenticated
    // guest agent advertises uinput. Custom VirGL has no VZ graphics device,
    // so its reliable desktop input path is the agent once userspace starts.
    private var absolutePointerEnabled = true

    init(frame frameRect: NSRect, guestSize: CGSize) {
        self.guestSize = guestSize
        super.init(frame: frameRect)
        wantsLayer = true
        backgroundLayer.backgroundColor = NSColor.black.cgColor
        layer = backgroundLayer
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.backgroundColor = NSColor.black.cgColor
        backgroundLayer.addSublayer(metalLayer)
        cursorLayer.anchorPoint = .zero
        cursorLayer.contentsGravity = .resize
        cursorLayer.isHidden = true
        metalLayer.addSublayer(cursorLayer)
        // Forward Command/Super and the other system-key chords to Linux just
        // like a normal VZVirtualMachineView. The host full-screen command is
        // still handled by the window controller before it reaches the view.
        capturesSystemKeys = true
        automaticallyReconfiguresDisplay = false
        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let vmWindow = self.window,
                  vmWindow.isKeyWindow,
                  NSApp.keyWindow === vmWindow,
                  NSApp.modalWindow == nil,
                  !NSApp.windows.contains(where: {
                      $0.isVisible && ($0 is NSOpenPanel || $0 is NSSavePanel)
                  }),
                  vmWindow.attachedSheet == nil else { return event }
            // Accessibility input and some system-key event sources leave the
            // event's window unset even though AppKit is dispatching to the key
            // VM window. Accept that form, but never steal a chord explicitly
            // associated with another EZVM window.
            if let eventWindow = event.window, eventWindow !== vmWindow { return event }
            if let responderView = vmWindow.firstResponder as? NSView,
               responderView !== self, !responderView.isDescendant(of: self) {
                return event
            }
            if self.isHostFullScreenShortcut(event) { return event }
            return self.forwardCommandChordToGuest(event) ? nil : event
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        focusedCommandEventTap?.stop()
        accessibilityRetryTimer?.invalidate()
        if let commandKeyMonitor { NSEvent.removeMonitor(commandKeyMonitor) }
        displayRefreshTimer?.invalidate()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        releaseInputCapture()
    }

    func stopPresentation() {
        focusedCommandEventTap?.stop()
        focusedCommandEventTap = nil
        accessibilityRetryTimer?.invalidate()
        accessibilityRetryTimer = nil
        presentationLifecycle.stop()
        displayRefreshTimer?.invalidate()
        displayRefreshTimer = nil
        latestScanout = nil
        presentationInFlight = false
        cursorLayer.isHidden = true
        runtimeIssueHandler?(nil)
        releaseInputCapture()
    }

    func invalidateScanout(eventSequence: UInt64) {
        guard presentationEventFence.accept(eventSequence) else { return }
        latestScanout = nil
        displayRefreshTimer?.invalidate()
        displayRefreshTimer = nil
    }

    override var acceptsFirstResponder: Bool { true }

    func setGuestInputHandler(_ handler: (([VMGuestAgentInputEvent]) -> Void)?) {
        focusedCommandEventTap?.stop()
        focusedCommandEventTap = nil
        guestInputHandler = handler
        guard handler != nil else {
            keyboardIntegrationStateHandler?(.waitingForGuest)
            return
        }
        installFocusedCommandEventTap()
    }

    func setKeyboardIntegrationStateHandler(
        _ handler: ((VMKeyboardIntegrationState) -> Void)?
    ) {
        keyboardIntegrationStateHandler = handler
        if focusedCommandEventTap != nil {
            handler?(.enabled)
        } else if guestInputHandler == nil {
            handler?(.waitingForGuest)
        } else {
            handler?(.accessibilityRequired)
        }
    }

    func requestKeyboardIntegrationPermission() {
        guard guestInputHandler != nil else {
            keyboardIntegrationStateHandler?(.waitingForGuest)
            return
        }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        accessibilityRetryTimer?.invalidate()
        var attemptsRemaining = 40
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self, self.guestInputHandler != nil else {
                timer.invalidate()
                return
            }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.accessibilityRetryTimer = nil
                self.installFocusedCommandEventTap()
                return
            }
            attemptsRemaining -= 1
            if attemptsRemaining == 0 {
                timer.invalidate()
                self.accessibilityRetryTimer = nil
                self.keyboardIntegrationStateHandler?(.accessibilityRequired)
            }
        }
        accessibilityRetryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        keyboardIntegrationStateHandler?(.accessibilityRequired)
    }

    private func installFocusedCommandEventTap() {
        guard focusedCommandEventTap == nil, let handler = guestInputHandler else { return }
        let eventTap = VMFocusedCommandEventTap(
            focusProbe: { [weak self] in self?.shouldCaptureSystemKeys == true },
            eventHandler: handler
        )
        if eventTap.start() {
            focusedCommandEventTap = eventTap
            keyboardIntegrationStateHandler?(.enabled)
            EZVMLog.info("Focused Command/Super event tap enabled", logger: EZVMLog.input)
        } else {
            keyboardIntegrationStateHandler?(.accessibilityRequired)
            EZVMLog.error(
                "Focused Command/Super event tap unavailable; grant Accessibility permission for system shortcuts",
                logger: EZVMLog.input
            )
        }
    }

    private var shouldCaptureSystemKeys: Bool {
        guard guestInputHandler != nil,
              let vmWindow = window,
              vmWindow.isKeyWindow,
              NSApp.isActive,
              NSApp.keyWindow === vmWindow,
              NSApp.modalWindow == nil,
              vmWindow.attachedSheet == nil,
              !NSApp.windows.contains(where: {
                  $0.isVisible && ($0 is NSOpenPanel || $0 is NSSavePanel)
              }) else { return false }
        guard let responder = vmWindow.firstResponder else { return false }
        if responder === self { return true }
        return (responder as? NSView)?.isDescendant(of: self) == true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if releaseShortcutIsActive(event) {
            releaseInputCapture()
            return
        }
        // `capturesSystemKeys` normally makes AppKit offer Command chords via
        // `performKeyEquivalent`, but some event sources (including hardware
        // layouts and accessibility event injection) deliver them directly as
        // key-down events. Cover both routes so macOS Command consistently
        // becomes Linux Super instead of silently disappearing.
        if forwardCommandChordToGuest(event) { return }
        if let guestInputHandler {
            let effectiveFlags = VMGuestAgentKeyboard.effectiveModifierFlags(
                reported: event.modifierFlags,
                characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            )
            if !event.isARepeat,
               let events = VMGuestAgentKeyboard.chordEventsForMissingModifierTransition(
                   forMacVirtualKey: event.keyCode,
                   modifierFlags: effectiveFlags,
                   alreadyPressed: pressedKeys
               ) {
                guestInputHandler(events)
                EZVMLog.info(
                    "Synthesized missing guest modifier transition for keyCode=\(event.keyCode)",
                    logger: EZVMLog.input
                )
                return
            }
            guard let code = VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: event.keyCode) else {
                super.keyDown(with: event)
                return
            }
            if !event.isARepeat, !pressedKeys.contains(code) {
                sendKey(code: code, pressed: true, using: guestInputHandler)
            }
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if let guestInputHandler,
           let code = VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: event.keyCode) {
            if pressedKeys.contains(code) {
                sendKey(code: code, pressed: false, using: guestInputHandler)
            }
            return
        }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if let guestInputHandler,
           let code = VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: event.keyCode),
           let pressed = VMGuestAgentKeyboard.modifierPressed(
               forMacVirtualKey: event.keyCode,
               flags: event.modifierFlags
           ) {
            if pressed != pressedKeys.contains(code) {
                sendKey(code: code, pressed: pressed, using: guestInputHandler)
            }
            return
        }
        super.flagsChanged(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isHostFullScreenShortcut(event) { return false }
        if forwardCommandChordToGuest(event) { return true }
        // Non-Command equivalents and pre-agent firmware input retain the VZ
        // native fallback. Ordinary desktop key events are handled above.
        return super.performKeyEquivalent(with: event)
    }

    private func forwardCommandChordToGuest(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }
        guard !event.isARepeat else { return true }
        guard let guestInputHandler,
              let events = VMGuestAgentKeyboard.chordEvents(
                forMacVirtualKey: event.keyCode,
                modifierFlags: flags,
                alreadyPressed: pressedKeys
              ) else { return false }
        // AppKit consumes host Command shortcuts before VZ's native USB
        // keyboard sees them. Send a complete, synchronized Linux Super chord
        // through the standard uinput keyboard instead.
        guestInputHandler(events)
        EZVMLog.info(
            "Forwarded host Command chord through guest keyboard keyCode=\(event.keyCode)",
            logger: EZVMLog.input
        )
        return true
    }

    private func isHostFullScreenShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 3 && flags.contains([.command, .control])
    }

    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event) }
    override func mouseDragged(with event: NSEvent) { super.mouseDragged(with: event) }
    override func rightMouseDragged(with event: NSEvent) { super.rightMouseDragged(with: event) }
    override func otherMouseDragged(with event: NSEvent) { super.otherMouseDragged(with: event) }
    override func mouseDown(with event: NSEvent) {
        restoreKeyboardFocus()
        super.mouseDown(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        restoreKeyboardFocus()
        super.rightMouseDown(with: event)
    }
    override func rightMouseUp(with event: NSEvent) {
        super.rightMouseUp(with: event)
    }
    override func otherMouseDown(with event: NSEvent) {
        restoreKeyboardFocus()
        super.otherMouseDown(with: event)
    }
    override func otherMouseUp(with event: NSEvent) {
        super.otherMouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let guestInputHandler else {
            super.scrollWheel(with: event)
            return
        }
        let detents = scrollWheelAccumulator.consume(
            delta: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )
        guard detents != 0 else { return }
        guestInputHandler([
            VMGuestAgentInputEvent(type: 2, code: 8, value: detents),
            VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
        ])
    }

    private func sendRelativeMotion(_ event: NSEvent) {
        guard pointerCaptured else { return }
        let x = Int32(max(-32767, min(32767, Int(event.deltaX.rounded()))))
        let y = Int32(max(-32767, min(32767, Int(event.deltaY.rounded()))))
        guard x != 0 || y != 0 else { return }
        var events: [VMGuestAgentInputEvent] = []
        if x != 0 { events.append(.init(type: 2, code: 0, value: x)) }
        if y != 0 { events.append(.init(type: 2, code: 1, value: y)) }
        events.append(.init(type: 0, code: 0, value: 0))
        guestInputHandler?(events)
    }

    private func sendAbsolutePosition(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let coordinates = VMAbsolutePointerMapper.coordinates(
            for: point,
            in: metalLayer.frame
        ) else { return }
        guestInputHandler?(VMAbsolutePointerMapper.events(x: coordinates.x, y: coordinates.y))
    }

    func setAbsolutePointerEnabled(_ enabled: Bool) {
        guard absolutePointerEnabled != enabled else { return }
        absolutePointerEnabled = enabled
        if enabled { releaseInputCapture() }
        // In absolute mode the native macOS cursor is already at the exact
        // guest position. Hide the separately composited GPU cursor to avoid
        // a delayed duplicate while preserving natural boundary crossing.
        cursorLayer.isHidden = enabled || cursorLayer.contents == nil
        EZVMLog.info("VirGL absolute pointer enabled=\(enabled)", logger: EZVMLog.graphics)
    }

    private func sendButton(code: UInt16, pressed: Bool) {
        if pressed { pressedButtons.insert(code) } else { pressedButtons.remove(code) }
        guestInputHandler?(VMGuestAgentInputBatch.key(code: code, pressed: pressed).events)
    }

    private func sendKey(
        code: UInt16,
        pressed: Bool,
        using handler: ([VMGuestAgentInputEvent]) -> Void
    ) {
        if pressed { pressedKeys.insert(code) } else { pressedKeys.remove(code) }
        handler(VMGuestAgentInputBatch.key(code: code, pressed: pressed).events)
    }

    private func ensureDisplayRefreshTimer() {
        guard displayRefreshTimer == nil else { return }
        // VirGL exposes a live, zero-copy scanout texture. Wayland may update
        // that texture without issuing RESOURCE_FLUSH for every visible change,
        // so presentation must follow the host display clock instead of relying
        // exclusively on guest damage notifications.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard let scanout = self.latestScanout else { return }
            self.presentFrame(
                resourceID: scanout.resourceID,
                x: scanout.x, y: scanout.y,
                width: scanout.width,
                height: scanout.height
            )
        }
        displayRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func releaseShortcutIsActive(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains([.control, .option])
    }

    private func restoreKeyboardFocus() {
        guard let window else { return }
        if !window.isKeyWindow { window.makeKey() }
        window.makeFirstResponder(self)
    }

    private func capturePointer() {
        guard !pointerCaptured, window?.isKeyWindow == true else { return }
        pointerCaptured = true
        restoreKeyboardFocus()
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
    }

    private func releaseInputCapture() {
        if let guestInputHandler {
            for code in pressedKeys.sorted() {
                guestInputHandler(VMGuestAgentInputBatch.key(code: code, pressed: false).events)
            }
            for code in pressedButtons.sorted() {
                guestInputHandler(VMGuestAgentInputBatch.key(code: code, pressed: false).events)
            }
        }
        pressedKeys.removeAll()
        pressedButtons.removeAll()
        guard pointerCaptured else { return }
        pointerCaptured = false
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        NSCursor.unhide()
    }

    override func layout() {
        super.layout()
        updateDrawableGeometry()
        updateCursorGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        window?.acceptsMouseMovedEvents = true
        guard let window else {
            releaseInputCapture()
            return
        }
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in self?.releaseInputCapture() })
        windowObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in self?.releaseInputCapture() })
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
        super.updateTrackingAreas()
    }

    func updateCursor(_ update: EZVMVirGLRuntime.CursorUpdate) {
        guard presentationLifecycle.tokenForPresentation() != nil else { return }
        cursorPosition = CGPoint(x: Int(update.x), y: Int(update.y))
        if update.replacesImage {
            cursorHotspot = CGPoint(x: Int(update.hotX), y: Int(update.hotY))
            if let image = update.image {
                cursorLayer.contents = image
                cursorImageSize = CGSize(width: image.width, height: image.height)
            } else {
                cursorLayer.contents = nil
                cursorImageSize = .zero
            }
        }
        cursorLayer.isHidden = absolutePointerEnabled || !update.isVisible
        updateCursorGeometry()
    }

    func present(
        resourceID: UInt32,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        eventSequence: UInt64
    ) {
        guard presentationLifecycle.tokenForPresentation() != nil else { return }
        guard presentationEventFence.accept(eventSequence) else { return }
        latestScanout = (resourceID, x, y, width, height)
        ensureDisplayRefreshTimer()
        presentFrame(resourceID: resourceID, x: x, y: y, width: width, height: height)
    }

    private func presentFrame(resourceID: UInt32, x: Int, y: Int, width: Int, height: Int) {
        guard let presentationToken = presentationLifecycle.tokenForPresentation() else { return }
        requestedFramesInWindow &+= 1
        if width > 0, height > 0 {
            guestSize = CGSize(width: width, height: height)
        }
        updateDrawableGeometry()
        // ANGLE's GL-to-Metal blit is serialized on the renderer thread. Never
        // wait for it on AppKit's main thread: doing so delays keyboard and
        // mouse event dispatch and makes guest text appear only after a later
        // pointer event. One in-flight drawable is sufficient because the
        // scanout texture is live and the display timer will pick up its newest
        // contents on the next tick.
        guard !presentationInFlight else {
            recordPerformanceIfNeeded()
            return
        }
        guard let runtime else {
            failuresInWindow &+= 1
            recordPresentationResult(success: false)
            recordPerformanceIfNeeded()
            return
        }
        guard let drawable = metalLayer.nextDrawable() else {
            drawableMissesInWindow &+= 1
            recordPerformanceIfNeeded()
            return
        }
        presentationInFlight = true
        let startedAt = CACurrentMediaTime()
        runtime.presentAsync(
            resourceID: resourceID,
            sourceX: x, sourceY: y, sourceWidth: width, sourceHeight: height,
            into: drawable.texture
        ) { [weak self] succeeded in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.presentationLifecycle.acceptsCompletion(token: presentationToken) else { return }
                if succeeded { drawable.present() }
                self.presentationInFlight = false
                if succeeded {
                    self.recordPresentationResult(success: true)
                    let duration = CACurrentMediaTime() - startedAt
                    self.totalPresentationTimeInWindow += duration
                    self.maximumPresentationTimeInWindow = max(self.maximumPresentationTimeInWindow, duration)
                    self.presentationDurationsInWindow.append(duration)
                    self.presentedFrames &+= 1
                    self.presentedFramesInWindow &+= 1
                    if self.presentedFrames == 1 || self.presentedFrames.isMultiple(of: 600) {
                        EZVMLog.info("VirGL zero-copy frames presented: \(self.presentedFrames)", logger: EZVMLog.graphics)
                    }
                } else {
                    self.failuresInWindow &+= 1
                    self.recordPresentationResult(success: false)
                    EZVMLog.error("VirGL zero-copy presentation failed for resource \(resourceID)")
                }
                self.recordPerformanceIfNeeded()
            }
        }
    }

    private func recordPresentationResult(success: Bool) {
        switch presentationHealth.record(success: success) {
        case .none:
            break
        case .degraded:
            runtimeIssueHandler?(
                String(localized: "Custom VirGL repeatedly failed to present the guest display. The VM is still running; if the display does not recover, stop it and disable Custom VirGL before restarting.")
            )
        case .recovered:
            runtimeIssueHandler?(nil)
        }
    }

    private func recordPerformanceIfNeeded() {
        let now = CACurrentMediaTime()
        let elapsed = now - performanceWindowStartedAt
        guard elapsed >= 5 else { return }
        let fps = Double(presentedFramesInWindow) / elapsed
        let averageMilliseconds = presentedFramesInWindow == 0
            ? 0
            : totalPresentationTimeInWindow * 1_000 / Double(presentedFramesInWindow)
        let sortedDurations = presentationDurationsInWindow.sorted()
        let p95Milliseconds: Double
        if sortedDurations.isEmpty {
            p95Milliseconds = 0
        } else {
            let percentileIndex = Int(ceil(Double(sortedDurations.count) * 0.95)) - 1
            p95Milliseconds = sortedDurations[max(0, percentileIndex)] * 1_000
        }
        let drawable = metalLayer.drawableSize
        let summary = String(
                format: "VirGL performance: fps=%.1f requested=%llu presented=%llu drawableMisses=%llu failures=%llu avgPresentMs=%.2f p95PresentMs=%.2f maxPresentMs=%.2f drawable=%.0fx%.0f",
                fps,
                requestedFramesInWindow,
                presentedFramesInWindow,
                drawableMissesInWindow,
                failuresInWindow,
                averageMilliseconds,
                p95Milliseconds,
                maximumPresentationTimeInWindow * 1_000,
                drawable.width,
                drawable.height
            )
        EZVMLog.info(summary, logger: EZVMLog.graphics)
        if ProcessInfo.processInfo.environment["EZVM_VIRGL_DIAGNOSTICS"] == "1",
           let file = fopen("/tmp/ezvm-virgl-presentation.log", "a") {
            fputs("\(summary) bounds=\(Int(bounds.width))x\(Int(bounds.height)) guest=\(Int(guestSize.width))x\(Int(guestSize.height)) layer=\(Int(metalLayer.frame.width))x\(Int(metalLayer.frame.height))\n", file)
            fclose(file)
        }
        performanceWindowStartedAt = now
        requestedFramesInWindow = 0
        presentedFramesInWindow = 0
        drawableMissesInWindow = 0
        failuresInWindow = 0
        totalPresentationTimeInWindow = 0
        maximumPresentationTimeInWindow = 0
        presentationDurationsInWindow.removeAll(keepingCapacity: true)
    }

    private func updateDrawableGeometry() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let presentationFrame = VMDisplayGeometry.aspectFit(content: guestSize, in: bounds)
        metalLayer.frame = presentationFrame
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(1, presentationFrame.width * scale),
            height: max(1, presentationFrame.height * scale)
        )
    }

    private func updateCursorGeometry() {
        guard guestSize.width > 0, guestSize.height > 0 else { return }
        let presentationSize = metalLayer.bounds.size
        let scaleX = presentationSize.width / guestSize.width
        let scaleY = presentationSize.height / guestSize.height
        let width = cursorImageSize.width * scaleX
        let height = cursorImageSize.height * scaleY
        let x = (cursorPosition.x - cursorHotspot.x) * scaleX
        let top = (cursorPosition.y - cursorHotspot.y) * scaleY
        cursorLayer.frame = CGRect(x: x, y: presentationSize.height - top - height, width: width, height: height)
    }
}

@available(macOS 27.0, *)
final class VMCustomVirGLGraphicsBackend: VMGraphicsBackend {
    let kind = VMGraphicsBackendKind.customVirGL
    // Restoring guest RAM alone cannot reconstruct VirGL contexts, resources,
    // fences, or renderer command-stream state. Keep VZ machine-state saving
    // disabled until the complete GPU state has a versioned representation.
    let supportsMachineSaveRestore = false
    let displayView: NSView
    private let virglView: VMVirGLDisplayView
    private var runtime: EZVMVirGLRuntime?
    private let deviceConfigurations: [VZCustomVirtioDeviceConfiguration]
    private var requestedResolution: (width: UInt32, height: UInt32)?
    private var pendingDisplayRequest: DispatchWorkItem?
    private var dynamicDisplayReady = false
    private let dynamicDisplayEnabled = ProcessInfo.processInfo.environment[
        "EZVM_DISABLE_DYNAMIC_VIRGL_DISPLAY"
    ] != "1"

    init(devices: [VMModelFieldGraphicDevice]) throws {
        let device = devices.first ?? .default(osType: .linux)
        let initialResolution = VMDisplayGeometry.guestResolution(for: CGSize(
            width: max(1, device.width),
            height: max(1, device.height)
        ))
        let dependencies = VirGLRuntimeDependencies.resolve()
        try dependencies.validate()
        let view = VMVirGLDisplayView(
            frame: .zero,
            guestSize: CGSize(
                width: Int(initialResolution.width),
                height: Int(initialResolution.height)
            )
        )
        virglView = view
        displayView = view
        let runtime = try EZVMVirGLRuntime(
            configuration: .init(
                width: initialResolution.width,
                height: initialResolution.height,
                rendererLibraryURL: dependencies.virglRendererURL,
                experimentalStaticInputEnabled: ProcessInfo.processInfo.environment[
                    "EZVM_EXPERIMENTAL_STATIC_VIRTIO_INPUT"
                ] == "1"
            ),
            onScanout: { [weak view] resourceID, x, y, width, height, eventSequence in
                view?.present(
                    resourceID: resourceID,
                    x: x, y: y, width: width, height: height,
                    eventSequence: eventSequence
                )
            },
            onScanoutInvalidated: { [weak view] eventSequence in
                view?.invalidateScanout(eventSequence: eventSequence)
            },
            onCursor: { [weak view] update in
                view?.updateCursor(update)
            }
        )
        // Create every Virtualization.framework device while the backend is
        // still inside the factory's recoverable initialization boundary. If
        // this fails, the factory can discard the runtime and select Apple
        // Virtio before a VZVirtualMachine or guest-visible device exists.
        let deviceConfigurations = try runtime.makeDeviceConfigurations()
        self.runtime = runtime
        self.deviceConfigurations = deviceConfigurations
        requestedResolution = initialResolution
        view.runtime = runtime
    }

    func applyGraphics(
        from devices: [VMModelFieldGraphicDevice],
        to configuration: VZVirtualMachineConfiguration
    ) -> VMOSResultVoid {
        configuration.graphicsDevices = []
        configuration.customVirtioDevices.append(contentsOf: deviceConfigurations)
        return .success
    }

    func bind(virtualMachine: VZVirtualMachine?) {
        virglView.virtualMachine = virtualMachine
    }

    func refreshDisplayConfiguration() {
        guard dynamicDisplayEnabled else {
            let size = virglView.bounds.size
            EZVMLog.info(
                "VirGL stable-canvas scaling: logical=\(Int(size.width))x\(Int(size.height))",
                logger: EZVMLog.graphics
            )
            return
        }
        // A Linux text console can acknowledge a new virtio-gpu mode and then
        // immediately replace it with its 800x600 fbcon fallback. Omarchy's
        // first-boot form runs on that console, before Hyprland and its display
        // watcher exist. Keep the persisted 1280x720 boot mode until the Guest
        // Agent reports a real desktop session; otherwise the setup UI becomes
        // cropped even though host-side mode negotiation succeeded.
        guard dynamicDisplayReady else { return }
        // A macOS full-screen transition exposes several short-lived content
        // sizes (including the toolbar-safe-area width). Sending each one to
        // DRM makes Hyprland destroy and recreate its triple buffers multiple
        // times in under a second. Coalesce the whole transition and sample
        // the view again only after its final geometry has settled.
        pendingDisplayRequest?.cancel()
        let request = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let size = self.virglView.bounds.size
            let candidate = VMDisplayGeometry.guestResolution(for: size)
            let resolution = VMDisplayGeometry.stabilizedResolution(
                candidate: candidate,
                current: self.requestedResolution ?? candidate
            )
            EZVMLog.info(
                "VirGL stable display request: logical=\(Int(size.width))x\(Int(size.height)) candidate=\(candidate.width)x\(candidate.height) guest=\(resolution.width)x\(resolution.height)",
                logger: EZVMLog.graphics
            )
            guard self.requestedResolution?.width != resolution.width
                    || self.requestedResolution?.height != resolution.height else { return }
            self.requestedResolution = resolution
            self.runtime?.requestDisplaySize(width: resolution.width, height: resolution.height)
        }
        pendingDisplayRequest = request
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: request)
    }

    func setDynamicDisplayReady(_ ready: Bool) {
        guard dynamicDisplayReady != ready else { return }
        dynamicDisplayReady = ready
        if ready {
            requestedResolution = nil
            refreshDisplayConfiguration()
        } else {
            pendingDisplayRequest?.cancel()
            pendingDisplayRequest = nil
        }
    }

    func setGuestInputHandler(_ handler: (([VMGuestAgentInputEvent]) -> Void)?) {
        virglView.setGuestInputHandler(handler)
    }

    func setKeyboardIntegrationStateHandler(
        _ handler: ((VMKeyboardIntegrationState) -> Void)?
    ) {
        virglView.setKeyboardIntegrationStateHandler(handler)
    }

    func requestKeyboardIntegrationPermission() {
        virglView.requestKeyboardIntegrationPermission()
    }

    func setAbsolutePointerEnabled(_ enabled: Bool) {
        virglView.setAbsolutePointerEnabled(enabled)
    }

    func setRuntimeIssueHandler(_ handler: ((String?) -> Void)?) {
        virglView.runtimeIssueHandler = handler
    }

    func shutdown() {
        pendingDisplayRequest?.cancel()
        pendingDisplayRequest = nil
        virglView.stopPresentation()
        virglView.virtualMachine = nil
        virglView.setGuestInputHandler(nil)
        virglView.setKeyboardIntegrationStateHandler(nil)
        virglView.runtimeIssueHandler = nil
        virglView.runtime = nil
        runtime?.shutdown()
        runtime = nil
    }
}

struct VMGraphicsBackendCreation {
    let backend: any VMGraphicsBackend
    let detail: String?
}

enum VMGraphicsBackendFactory {
    // This flips to true only when the production Custom Virtio GPU runtime,
    // presenter, and lifecycle implementation are linked into the app target.
    static let customBackendImplemented = true

    static func selection(
        forLinux: Bool = true,
        hasInstallationMedia: Bool = false,
        guestInputReady: Bool = true
    ) -> VMGraphicsBackendSelection {
        VMGraphicsBackendSelection.resolve(
            isLinux: forLinux,
            hostSupportsCustomVirtio: VirtualizationCapability.customVirtio.isAvailable,
            experimentalEnabled: EZVMExperimentalFeatures.customVirGLGraphicsEnabled(),
            customBackendImplemented: customBackendImplemented,
            hasInstallationMedia: hasInstallationMedia,
            guestInputReady: guestInputReady
        )
    }

    static func make(
        forLinux: Bool = true,
        devices: [VMModelFieldGraphicDevice],
        hasInstallationMedia: Bool = false,
        guestInputReady: Bool = true,
        forceAppleGraphics: Bool = false
    ) -> VMGraphicsBackendCreation {
        if forceAppleGraphics {
            return VMGraphicsBackendCreation(
                backend: VMAppleGraphicsBackend(),
                detail: "Apple Virtio graphics selected for release comparison."
            )
        }
        let selection = selection(
            forLinux: forLinux,
            hasInstallationMedia: hasInstallationMedia,
            guestInputReady: guestInputReady
        )
        if let fallbackReason = selection.fallbackReason {
            EZVMLog.info("Graphics backend fallback: \(fallbackReason)")
        }
        // The exhaustive switch intentionally makes adding the production
        // backend a compiler-visible integration point.
        switch selection.active {
        case .appleVirtio:
            return VMGraphicsBackendCreation(
                backend: VMAppleGraphicsBackend(), detail: selection.fallbackReason
            )
        case .customVirGL:
            if #available(macOS 27.0, *) {
                do {
                    return VMGraphicsBackendCreation(
                        backend: try VMCustomVirGLGraphicsBackend(devices: devices), detail: nil
                    )
                } catch {
                    let detail = "Custom VirGL could not start: \(error.localizedDescription)"
                    EZVMLog.error(
                        "Custom VirGL initialization failed; using Apple Virtio: \(String(reflecting: error))"
                    )
                    return VMGraphicsBackendCreation(
                        backend: VMAppleGraphicsBackend(), detail: detail
                    )
                }
            }
            return VMGraphicsBackendCreation(
                backend: VMAppleGraphicsBackend(),
                detail: "The Custom VirGL backend requires macOS 27 or later."
            )
        }
    }
}

#endif
