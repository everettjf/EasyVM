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
    func setAbsolutePointerEnabled(_ enabled: Bool)
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

    func setAbsolutePointerEnabled(_ enabled: Bool) {}

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
    private var keyEquivalentMonitor: Any?
    private var guestSize: CGSize
    private var scrollWheelAccumulator = VMScrollWheelAccumulator()
    private var latestScanout: (resourceID: UInt32, x: Int, y: Int, width: Int, height: Int)?
    private var displayRefreshTimer: Timer?
    private var presentationInFlight = false
    // Input is provided by Virtualization.framework's native USB keyboard and
    // screen-coordinate pointing devices. It must work before a userspace
    // guest agent starts (notably in firmware and at the display manager).
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
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        displayRefreshTimer?.invalidate()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        if let keyEquivalentMonitor { NSEvent.removeMonitor(keyEquivalentMonitor) }
        releaseInputCapture()
    }

    func stopPresentation() {
        displayRefreshTimer?.invalidate()
        displayRefreshTimer = nil
        latestScanout = nil
        releaseInputCapture()
    }

    func invalidateScanout() {
        latestScanout = nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if releaseShortcutIsActive(event) {
            releaseInputCapture()
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isHostFullScreenShortcut(event) { return false }
        // VZVirtualMachineView owns Mac-keyboard to USB-keyboard translation,
        // including Command -> Linux Super. This path is available at login.
        return super.performKeyEquivalent(with: event)
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
        super.scrollWheel(with: event)
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
        if let keyEquivalentMonitor { NSEvent.removeMonitor(keyEquivalentMonitor) }
        keyEquivalentMonitor = nil
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
        cursorLayer.isHidden = absolutePointerEnabled || !update.isVisible
        updateCursorGeometry()
    }

    func present(resourceID: UInt32, x: Int, y: Int, width: Int, height: Int) {
        latestScanout = (resourceID, x, y, width, height)
        ensureDisplayRefreshTimer()
        presentFrame(resourceID: resourceID, x: x, y: y, width: width, height: height)
    }

    private func presentFrame(resourceID: UInt32, x: Int, y: Int, width: Int, height: Int) {
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
            if succeeded { drawable.present() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.presentationInFlight = false
                if succeeded {
                    let duration = CACurrentMediaTime() - startedAt
                    self.totalPresentationTimeInWindow += duration
                    self.maximumPresentationTimeInWindow = max(self.maximumPresentationTimeInWindow, duration)
                    self.presentedFrames &+= 1
                    self.presentedFramesInWindow &+= 1
                    if self.presentedFrames == 1 || self.presentedFrames.isMultiple(of: 600) {
                        EZVMLog.info("VirGL zero-copy frames presented: \(self.presentedFrames)", logger: EZVMLog.graphics)
                    }
                } else {
                    self.failuresInWindow &+= 1
                    EZVMLog.error("VirGL zero-copy presentation failed for resource \(resourceID)")
                }
                self.recordPerformanceIfNeeded()
            }
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
    private var requestedResolution: (width: UInt32, height: UInt32)?
    private var pendingDisplayRequest: DispatchWorkItem?
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
            onScanout: { [weak view] resourceID, x, y, width, height in
                view?.present(resourceID: resourceID, x: x, y: y, width: width, height: height)
            },
            onScanoutInvalidated: { [weak view] in
                view?.invalidateScanout()
            },
            onCursor: { [weak view] update in
                view?.updateCursor(update)
            }
        )
        self.runtime = runtime
        requestedResolution = initialResolution
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
        guard dynamicDisplayEnabled else {
            let size = virglView.bounds.size
            EZVMLog.info(
                "VirGL stable-canvas scaling: logical=\(Int(size.width))x\(Int(size.height))",
                logger: EZVMLog.graphics
            )
            return
        }
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

    func setGuestInputHandler(_ handler: (([VMGuestAgentInputEvent]) -> Void)?) {
        virglView.guestInputHandler = handler
    }

    func setAbsolutePointerEnabled(_ enabled: Bool) {
        virglView.setAbsolutePointerEnabled(enabled)
    }

    func shutdown() {
        pendingDisplayRequest?.cancel()
        pendingDisplayRequest = nil
        virglView.stopPresentation()
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
