//
//  VMModelFieldGraphicDevice.swift
//  EZVM
//
//  Created by everettjf on 2022/8/24.
//

import AppKit
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
    }
    
    let type: DeviceType
    let width: Int
    let height: Int
    let pixelsPerInch: Int
    
    var description: String {
        if type == .Virtio {
            return "\(type) \(width)*\(height)"
        } else {
            return "\(type) \(width)*\(height) (\(pixelsPerInch) PixelsPerInch)"
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
    func setGuestInputHandler(_ handler: (([VMGuestAgentInputEvent]) -> Void)?)
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

    func setGuestInputHandler(_ handler: (([VMGuestAgentInputEvent]) -> Void)?) {}

    func shutdown() {
        virtualMachineView.virtualMachine = nil
    }
}

@available(macOS 27.0, *)
final class VMVirGLDisplayView: VZVirtualMachineView {
    private let backgroundLayer = CALayer()
    private let metalLayer = CAMetalLayer()
    private let cursorLayer = CALayer()
    weak var runtime: EZVMVirGLRuntime?
    var guestInputHandler: (([VMGuestAgentInputEvent]) -> Void)?
    private var presentedFrames: UInt64 = 0
    private var performanceWindowStartedAt = CACurrentMediaTime()
    private var requestedFramesInWindow: UInt64 = 0
    private var presentedFramesInWindow: UInt64 = 0
    private var drawableMissesInWindow: UInt64 = 0
    private var failuresInWindow: UInt64 = 0
    private var totalPresentationTimeInWindow: TimeInterval = 0
    private var maximumPresentationTimeInWindow: TimeInterval = 0
    private var cursorPosition = CGPoint.zero
    private var cursorHotspot = CGPoint.zero
    private var cursorImageSize = CGSize.zero
    private var pressedKeys = Set<UInt16>()
    private var pressedButtons = Set<UInt16>()
    private var pointerCaptured = false
    private var windowObservers: [NSObjectProtocol] = []
    private var guestSize: CGSize
    private var scrollWheelAccumulator = VMScrollWheelAccumulator()

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
        automaticallyReconfiguresDisplay = false
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        releaseInputCapture()
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if releaseShortcutIsActive(event) {
            releaseInputCapture()
            return
        }
        if let code = VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: event.keyCode),
           let guestInputHandler {
            sendKey(code: code, pressed: true, using: guestInputHandler)
        } else if event.keyCode == 36 {
            runtime?.sendLinuxKey(code: 28, pressed: true)
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if let code = VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: event.keyCode),
           let guestInputHandler {
            sendKey(code: code, pressed: false, using: guestInputHandler)
        } else if event.keyCode == 36 {
            runtime?.sendLinuxKey(code: 28, pressed: false)
        } else {
            super.keyUp(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if pointerCaptured, releaseShortcutIsActive(event) {
            releaseInputCapture()
            return
        }
        guard let code = VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: event.keyCode),
              let flagIsSet = VMGuestAgentKeyboard.modifierPressed(
                forMacVirtualKey: event.keyCode,
                flags: event.modifierFlags
              ),
              let guestInputHandler else {
            super.flagsChanged(with: event)
            return
        }
        // AppKit reports one combined flag for the left and right variant.
        // Track each physical key so releasing left Shift while right Shift is
        // still held cannot turn left Shift back on in the guest.
        let pressed: Bool
        if event.keyCode == 57 { // Caps Lock is a host-side toggle, not a held flag.
            sendKey(code: code, pressed: true, using: guestInputHandler)
            sendKey(code: code, pressed: false, using: guestInputHandler)
            return
        } else if !flagIsSet {
            pressed = false
        } else {
            pressed = !pressedKeys.contains(code)
        }
        sendKey(code: code, pressed: pressed, using: guestInputHandler)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard (pointerCaptured || window?.firstResponder === self),
              !releaseShortcutIsActive(event),
              let code = VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: event.keyCode),
              let guestInputHandler else {
            return super.performKeyEquivalent(with: event)
        }
        sendKey(code: code, pressed: true, using: guestInputHandler)
        sendKey(code: code, pressed: false, using: guestInputHandler)
        return true
    }

    override func mouseMoved(with event: NSEvent) { sendRelativeMotion(event) }
    override func mouseDragged(with event: NSEvent) { sendRelativeMotion(event) }
    override func rightMouseDragged(with event: NSEvent) { sendRelativeMotion(event) }
    override func otherMouseDragged(with event: NSEvent) { sendRelativeMotion(event) }
    override func mouseDown(with event: NSEvent) {
        restoreKeyboardFocus()
        guard pointerCaptured else {
            capturePointer()
            return
        }
        sendButton(code: 272, pressed: true)
    }
    override func mouseUp(with event: NSEvent) {
        guard pointerCaptured else { return }
        sendButton(code: 272, pressed: false)
    }
    override func rightMouseDown(with event: NSEvent) {
        restoreKeyboardFocus()
        guard pointerCaptured else {
            capturePointer()
            return
        }
        sendButton(code: 273, pressed: true)
    }
    override func rightMouseUp(with event: NSEvent) { sendButton(code: 273, pressed: false) }
    override func otherMouseDown(with event: NSEvent) {
        restoreKeyboardFocus()
        guard pointerCaptured else {
            capturePointer()
            return
        }
        sendButton(code: 274, pressed: true)
    }
    override func otherMouseUp(with event: NSEvent) {
        guard pointerCaptured else { return }
        sendButton(code: 274, pressed: false)
    }

    override func scrollWheel(with event: NSEvent) {
        guard pointerCaptured else { return }
        let value = scrollWheelAccumulator.consume(
            delta: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )
        guard value != 0 else { return }
        guestInputHandler?([
            VMGuestAgentInputEvent(type: 2, code: 8, value: value),
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

    private func releaseShortcutIsActive(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains([.control, .option])
    }

    private func restoreKeyboardFocus() {
        guard window?.isKeyWindow == true else { return }
        window?.makeFirstResponder(self)
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
        cursorLayer.isHidden = !update.isVisible
        updateCursorGeometry()
    }

    func present(resourceID: UInt32, width: Int, height: Int) {
        requestedFramesInWindow &+= 1
        let startedAt = CACurrentMediaTime()
        if width > 0, height > 0 {
            guestSize = CGSize(width: width, height: height)
        }
        updateDrawableGeometry()
        guard let runtime else {
            failuresInWindow &+= 1
            recordPerformanceIfNeeded()
            return
        }
        guard let drawable = metalLayer.nextDrawable() else {
            drawableMissesInWindow &+= 1
            recordPerformanceIfNeeded()
            return
        }
        do {
            guard try runtime.present(resourceID: resourceID, into: drawable.texture) else {
                failuresInWindow &+= 1
                EZVMLog.error("VirGL zero-copy presentation failed for resource \(resourceID)")
                recordPerformanceIfNeeded()
                return
            }
            drawable.present()
            let duration = CACurrentMediaTime() - startedAt
            totalPresentationTimeInWindow += duration
            maximumPresentationTimeInWindow = max(maximumPresentationTimeInWindow, duration)
            presentedFrames &+= 1
            presentedFramesInWindow &+= 1
            if presentedFrames == 1 || presentedFrames.isMultiple(of: 600) {
                EZVMLog.info("VirGL zero-copy frames presented: \(presentedFrames)", logger: EZVMLog.graphics)
            }
        } catch {
            failuresInWindow &+= 1
            EZVMLog.error("VirGL presenter stopped: \(error.localizedDescription)")
        }
        recordPerformanceIfNeeded()
    }

    private func recordPerformanceIfNeeded() {
        let now = CACurrentMediaTime()
        let elapsed = now - performanceWindowStartedAt
        guard elapsed >= 5 else { return }
        let fps = Double(presentedFramesInWindow) / elapsed
        let averageMilliseconds = presentedFramesInWindow == 0
            ? 0
            : totalPresentationTimeInWindow * 1_000 / Double(presentedFramesInWindow)
        let drawable = metalLayer.drawableSize
        EZVMLog.info(
            String(
                format: "VirGL performance: fps=%.1f requested=%llu presented=%llu drawableMisses=%llu failures=%llu avgPresentMs=%.2f maxPresentMs=%.2f drawable=%.0fx%.0f",
                fps,
                requestedFramesInWindow,
                presentedFramesInWindow,
                drawableMissesInWindow,
                failuresInWindow,
                averageMilliseconds,
                maximumPresentationTimeInWindow * 1_000,
                drawable.width,
                drawable.height
            ),
            logger: EZVMLog.graphics
        )
        performanceWindowStartedAt = now
        requestedFramesInWindow = 0
        presentedFramesInWindow = 0
        drawableMissesInWindow = 0
        failuresInWindow = 0
        totalPresentationTimeInWindow = 0
        maximumPresentationTimeInWindow = 0
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

    init(devices: [VMModelFieldGraphicDevice]) throws {
        let device = devices.first ?? .default(osType: .linux)
        let dependencies = VirGLRuntimeDependencies.resolve()
        try dependencies.validate()
        let view = VMVirGLDisplayView(
            frame: .zero,
            guestSize: CGSize(width: max(1, device.width), height: max(1, device.height))
        )
        virglView = view
        displayView = view
        let runtime = try EZVMVirGLRuntime(
            configuration: .init(
                width: UInt32(max(1, device.width)),
                height: UInt32(max(1, device.height)),
                rendererLibraryURL: dependencies.virglRendererURL,
                experimentalStaticInputEnabled: ProcessInfo.processInfo.environment[
                    "EZVM_EXPERIMENTAL_STATIC_VIRTIO_INPUT"
                ] == "1"
            ),
            onScanout: { [weak view] resourceID, width, height in
                view?.present(resourceID: resourceID, width: width, height: height)
            },
            onCursor: { [weak view] update in
                view?.updateCursor(update)
            }
        )
        self.runtime = runtime
        view.runtime = runtime
    }

    func applyGraphics(
        from devices: [VMModelFieldGraphicDevice],
        to configuration: VZVirtualMachineConfiguration
    ) -> VMOSResultVoid {
        guard let runtime else { return .failure("The VirGL runtime stopped before VM configuration.") }
        do {
            configuration.graphicsDevices = []
            configuration.customVirtioDevices.append(contentsOf: try runtime.makeDeviceConfigurations())
            return .success
        } catch {
            return .failure("Could not configure the Custom VirGL GPU: \(error.localizedDescription)")
        }
    }

    func bind(virtualMachine: VZVirtualMachine?) {
        virglView.virtualMachine = virtualMachine
    }

    func refreshDisplayConfiguration() {
        let scale = virglView.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        let size = virglView.bounds.size
        let width = UInt32(max(640, min(8192, (size.width * scale).rounded())))
        let height = UInt32(max(480, min(8192, (size.height * scale).rounded())))
        EZVMLog.info(
            "VirGL display refresh: logical=\(Int(size.width))x\(Int(size.height)) scale=\(scale) requested=\(width)x\(height)",
            logger: EZVMLog.graphics
        )
        runtime?.requestDisplaySize(width: width, height: height)
    }

    func setGuestInputHandler(_ handler: (([VMGuestAgentInputEvent]) -> Void)?) {
        virglView.guestInputHandler = handler
    }

    func shutdown() {
        virglView.virtualMachine = nil
        virglView.guestInputHandler = nil
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

    static func selection(forLinux: Bool = true) -> VMGraphicsBackendSelection {
        VMGraphicsBackendSelection.resolve(
            isLinux: forLinux,
            hostSupportsCustomVirtio: VirtualizationCapability.customVirtio.isAvailable,
            experimentalEnabled: EZVMExperimentalFeatures.customVirGLGraphicsEnabled(),
            customBackendImplemented: customBackendImplemented
        )
    }

    static func make(
        forLinux: Bool = true,
        devices: [VMModelFieldGraphicDevice]
    ) -> VMGraphicsBackendCreation {
        let selection = selection(forLinux: forLinux)
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
