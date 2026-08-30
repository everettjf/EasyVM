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
    func applyGraphics(
        from devices: [VMModelFieldGraphicDevice],
        to configuration: VZVirtualMachineConfiguration
    ) -> VMOSResultVoid
    func bind(virtualMachine: VZVirtualMachine?)
    func shutdown()
}

final class VMAppleGraphicsBackend: VMGraphicsBackend {
    let kind = VMGraphicsBackendKind.appleVirtio
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

    func shutdown() {
        virtualMachineView.virtualMachine = nil
    }
}

@available(macOS 27.0, *)
final class VMVirGLDisplayView: VZVirtualMachineView {
    private let metalLayer = CAMetalLayer()
    weak var runtime: EZVMVirGLRuntime?
    private var presentedFrames: UInt64 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
        automaticallyReconfiguresDisplay = false
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateDrawableGeometry()
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
}

@available(macOS 27.0, *)
final class VMCustomVirGLGraphicsBackend: VMGraphicsBackend {
    let kind = VMGraphicsBackendKind.customVirGL
    let displayView: NSView
    private let virglView: VMVirGLDisplayView
    private var runtime: EZVMVirGLRuntime?

    init(devices: [VMModelFieldGraphicDevice]) throws {
        let device = devices.first ?? .default(osType: .linux)
        let dependencies = VirGLRuntimeDependencies.resolve()
        try dependencies.validate()
        let view = VMVirGLDisplayView(frame: .zero)
        virglView = view
        displayView = view
        let runtime = try EZVMVirGLRuntime(
            configuration: .init(
                width: UInt32(max(1, device.width)),
                height: UInt32(max(1, device.height)),
                rendererLibraryURL: dependencies.virglRendererURL
            ),
            onScanout: { [weak view] resourceID in
                view?.present(resourceID: resourceID)
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
            configuration.customVirtioDevices.append(try runtime.makeDeviceConfiguration())
            return .success
        } catch {
            return .failure("Could not configure the Custom VirGL GPU: \(error.localizedDescription)")
        }
    }

    func bind(virtualMachine: VZVirtualMachine?) {
        virglView.virtualMachine = virtualMachine
    }

    func shutdown() {
        virglView.virtualMachine = nil
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
