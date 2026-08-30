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

    func setGuestInputHandler(_ handler: (([VMGuestAgentInputEvent]) -> Void)?) {}

    func shutdown() {
        virtualMachineView.virtualMachine = nil
    }
}

@available(macOS 27.0, *)
final class VMVirGLDisplayView: VZVirtualMachineView {
    private let metalLayer = CAMetalLayer()
    private let cursorLayer = CALayer()
    weak var runtime: EZVMVirGLRuntime?
    var guestInputHandler: (([VMGuestAgentInputEvent]) -> Void)?
    private var presentedFrames: UInt64 = 0
    private var cursorPosition = CGPoint.zero
    private var cursorHotspot = CGPoint.zero
    private var cursorImageSize = CGSize.zero
    private let guestSize: CGSize

    init(frame frameRect: NSRect, guestSize: CGSize) {
        self.guestSize = guestSize
        super.init(frame: frameRect)
        wantsLayer = true
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
        cursorLayer.anchorPoint = .zero
        cursorLayer.contentsGravity = .resize
        cursorLayer.isHidden = true
        metalLayer.addSublayer(cursorLayer)
        automaticallyReconfiguresDisplay = false
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let code = VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: event.keyCode),
           let guestInputHandler {
            guestInputHandler(VMGuestAgentInputBatch.key(code: code, pressed: true).events)
        } else if event.keyCode == 36 {
            runtime?.sendLinuxKey(code: 28, pressed: true)
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if let code = VMGuestAgentKeyboard.linuxKeyCode(forMacVirtualKey: event.keyCode),
           let guestInputHandler {
            guestInputHandler(VMGuestAgentInputBatch.key(code: code, pressed: false).events)
        } else if event.keyCode == 36 {
            runtime?.sendLinuxKey(code: 28, pressed: false)
        } else {
            super.keyUp(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) { sendRelativeMotion(event) }
    override func mouseDragged(with event: NSEvent) { sendRelativeMotion(event) }
    override func rightMouseDragged(with event: NSEvent) { sendRelativeMotion(event) }
    override func otherMouseDragged(with event: NSEvent) { sendRelativeMotion(event) }
    override func mouseDown(with event: NSEvent) { sendButton(code: 272, pressed: true) }
    override func mouseUp(with event: NSEvent) { sendButton(code: 272, pressed: false) }
    override func rightMouseDown(with event: NSEvent) { sendButton(code: 273, pressed: true) }
    override func rightMouseUp(with event: NSEvent) { sendButton(code: 273, pressed: false) }

    override func scrollWheel(with event: NSEvent) {
        let value = Int32(max(-32767, min(32767, Int(event.scrollingDeltaY.rounded()))))
        guard value != 0 else { return }
        guestInputHandler?([
            VMGuestAgentInputEvent(type: 2, code: 8, value: value),
            VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
        ])
    }

    private func sendRelativeMotion(_ event: NSEvent) {
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
        guestInputHandler?(VMGuestAgentInputBatch.key(code: code, pressed: pressed).events)
    }

    override func layout() {
        super.layout()
        updateDrawableGeometry()
        updateCursorGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
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

    func present(resourceID: UInt32) {
        updateDrawableGeometry()
        guard let runtime, let drawable = metalLayer.nextDrawable() else { return }
        do {
            guard try runtime.present(resourceID: resourceID, into: drawable.texture) else {
                EZVMLog.error("VirGL zero-copy presentation failed for resource \(resourceID)")
                return
            }
            drawable.present()
            presentedFrames &+= 1
            if presentedFrames == 1 || presentedFrames.isMultiple(of: 600) {
                EZVMLog.info("VirGL zero-copy frames presented: \(presentedFrames)")
            }
        } catch {
            EZVMLog.error("VirGL presenter stopped: \(error.localizedDescription)")
        }
    }

    private func updateDrawableGeometry() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
    }

    private func updateCursorGeometry() {
        guard guestSize.width > 0, guestSize.height > 0 else { return }
        let scaleX = bounds.width / guestSize.width
        let scaleY = bounds.height / guestSize.height
        let width = cursorImageSize.width * scaleX
        let height = cursorImageSize.height * scaleY
        let x = (cursorPosition.x - cursorHotspot.x) * scaleX
        let top = (cursorPosition.y - cursorHotspot.y) * scaleY
        cursorLayer.frame = CGRect(x: x, y: bounds.height - top - height, width: width, height: height)
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
            onScanout: { [weak view] resourceID in
                view?.present(resourceID: resourceID)
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

enum VMGraphicsBackendFactory {
    // This flips to true only when the production Custom Virtio GPU runtime,
    // presenter, and lifecycle implementation are linked into the app target.
    static let customBackendImplemented = true

    static func selection(forLinux: Bool = true) -> VMGraphicsBackendSelection {
        VMGraphicsBackendSelection.resolve(
            isLinux: forLinux,
            hostSupportsCustomVirtio: VirtualizationCapability.customVirtio.isAvailable,
            experimentalEnabled: UserDefaults.standard.bool(
                forKey: EZVMExperimentalFeatures.customVirGLGraphicsKey
            ),
            customBackendImplemented: customBackendImplemented
        )
    }

    static func make(
        forLinux: Bool = true,
        devices: [VMModelFieldGraphicDevice]
    ) -> any VMGraphicsBackend {
        let selection = selection(forLinux: forLinux)
        if let fallbackReason = selection.fallbackReason {
            EZVMLog.info("Graphics backend fallback: \(fallbackReason)")
        }
        // The exhaustive switch intentionally makes adding the production
        // backend a compiler-visible integration point.
        switch selection.active {
        case .appleVirtio:
            return VMAppleGraphicsBackend()
        case .customVirGL:
            if #available(macOS 27.0, *) {
                do {
                    return try VMCustomVirGLGraphicsBackend(devices: devices)
                } catch {
                    EZVMLog.error(
                        "Custom VirGL initialization failed; using Apple Virtio: \(error.localizedDescription)"
                    )
                    return VMAppleGraphicsBackend()
                }
            }
            return VMAppleGraphicsBackend()
        }
    }
}

#endif
