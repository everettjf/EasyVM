import CoreGraphics
import Foundation
import Metal
@preconcurrency import Virtualization

/// Production-facing owner for the custom Virtio GPU, VirGL renderer, and
/// ANGLE/Metal presentation path. The command-line prototype is now only a
/// client of this API.
@available(macOS 27.0, *)
public final class EZVMVirGLRuntime: @unchecked Sendable {
    public struct CursorUpdate: @unchecked Sendable {
        public let image: CGImage?
        public let x: UInt32
        public let y: UInt32
        public let hotX: UInt32
        public let hotY: UInt32
        public let replacesImage: Bool
        public let isVisible: Bool

        init(
            image: CGImage?, x: UInt32, y: UInt32, hotX: UInt32, hotY: UInt32,
            replacesImage: Bool, isVisible: Bool
        ) {
            self.image = image
            self.x = x
            self.y = y
            self.hotX = hotX
            self.hotY = hotY
            self.replacesImage = replacesImage
            self.isVisible = isVisible
        }
    }

    public struct Configuration: Sendable, Equatable {
        public var width: UInt32
        public var height: UInt32
        public var rendererLibraryURL: URL
        public var zeroCopyPresentationEnabled: Bool
        public var experimentalStaticInputEnabled: Bool

        public init(
            width: UInt32,
            height: UInt32,
            rendererLibraryURL: URL,
            zeroCopyPresentationEnabled: Bool = true,
            experimentalStaticInputEnabled: Bool = false
        ) {
            self.width = width
            self.height = height
            self.rendererLibraryURL = rendererLibraryURL
            self.zeroCopyPresentationEnabled = zeroCopyPresentationEnabled
            self.experimentalStaticInputEnabled = experimentalStaticInputEnabled
        }
    }

    public enum RuntimeError: Error, CustomStringConvertible, LocalizedError {
        case renderer(String)
        case stopped

        public var description: String {
            switch self {
            case let .renderer(message): message
            case .stopped: "The VirGL runtime has already stopped."
            }
        }

        public var errorDescription: String? { description }
    }

    private let stateLock = NSLock()
    private var renderer: VirGLRenderer?
    private var gpuDevice: VirtioGPUDevice?
    private var inputProbeDevice: VirtioInputProbeDevice?

    public init(
        configuration: Configuration,
        onScanout: @escaping @MainActor @Sendable (UInt32, Int, Int, Int, Int) -> Void,
        onScanoutInvalidated: @escaping @MainActor @Sendable () -> Void = {},
        onCursor: @escaping @MainActor @Sendable (CursorUpdate) -> Void = { _ in },
        onFallbackFrame: @escaping @MainActor @Sendable (CGImage) -> Void = { _ in }
    ) throws {
        do {
            let renderer = try VirGLRenderer.acquire(libraryURL: configuration.rendererLibraryURL)
            self.renderer = renderer
            gpuDevice = VirtioGPUDevice(
                width: configuration.width,
                height: configuration.height,
                renderer: renderer,
                zeroCopyPresentationEnabled: configuration.zeroCopyPresentationEnabled,
                onZeroCopyFrame: { frame in
                    onScanout(frame.resourceID, frame.x, frame.y, frame.width, frame.height)
                },
                onScanoutInvalidated: onScanoutInvalidated,
                onCursor: onCursor,
                onFrame: onFallbackFrame
            )
            if configuration.experimentalStaticInputEnabled {
                inputProbeDevice = VirtioInputProbeDevice()
            }
        } catch {
            throw RuntimeError.renderer(String(describing: error))
        }
    }

    deinit { shutdown() }

    public func makeDeviceConfiguration() throws -> VZCustomVirtioDeviceConfiguration {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let gpuDevice else { throw RuntimeError.stopped }
        return gpuDevice.makeConfiguration()
    }

    public func makeDeviceConfigurations() throws -> [VZCustomVirtioDeviceConfiguration] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let gpuDevice else { throw RuntimeError.stopped }
        var configurations = [gpuDevice.makeConfiguration()]
        if let inputProbeDevice {
            configurations.append(inputProbeDevice.makeConfiguration())
        }
        return configurations
    }

    public func sendLinuxKey(code: UInt16, pressed: Bool) {
        stateLock.lock()
        let inputProbeDevice = self.inputProbeDevice
        stateLock.unlock()
        inputProbeDevice?.sendKey(code: code, pressed: pressed)
    }

    public func requestDisplaySize(width: UInt32, height: UInt32) {
        stateLock.lock()
        let gpuDevice = self.gpuDevice
        stateLock.unlock()
        gpuDevice?.requestDisplaySize(width: width, height: height)
    }

    public func present(
        resourceID: UInt32,
        sourceX: Int, sourceY: Int, sourceWidth: Int, sourceHeight: Int,
        into texture: any MTLTexture
    ) throws -> Bool {
        stateLock.lock()
        guard let renderer else {
            stateLock.unlock()
            throw RuntimeError.stopped
        }
        stateLock.unlock()
        return renderer.present(
            resourceID: resourceID,
            into: texture,
            sourceX: UInt32(sourceX), sourceY: UInt32(sourceY),
            sourceWidth: UInt32(sourceWidth), sourceHeight: UInt32(sourceHeight),
            width: UInt32(texture.width),
            height: UInt32(texture.height)
        )
    }

    public func presentAsync(
        resourceID: UInt32,
        sourceX: Int, sourceY: Int, sourceWidth: Int, sourceHeight: Int,
        into texture: any MTLTexture,
        completion: @escaping (Bool) -> Void
    ) {
        stateLock.lock()
        guard let renderer else {
            stateLock.unlock()
            completion(false)
            return
        }
        stateLock.unlock()
        renderer.presentAsync(
            resourceID: resourceID,
            into: texture,
            sourceX: UInt32(sourceX), sourceY: UInt32(sourceY),
            sourceWidth: UInt32(sourceWidth), sourceHeight: UInt32(sourceHeight),
            width: UInt32(texture.width),
            height: UInt32(texture.height),
            completion: completion
        )
    }

    /// Deterministic teardown for VM stop, failed startup, and window close.
    /// Dropping the device first releases all renderer-backed guest resources;
    /// dropping the renderer then cleans ANGLE/VirGL on its dedicated thread.
    public func shutdown() {
        stateLock.lock()
        gpuDevice = nil
        inputProbeDevice = nil
        let renderer = self.renderer
        self.renderer = nil
        stateLock.unlock()
        // virglrenderer is process-global. VZVirtualMachine may retain its
        // custom-device delegate past the VM stop callback, so ARC alone is not
        // a deterministic cleanup boundary. Tear the singleton down explicitly
        // before another VM in this app process attempts initialization.
        renderer?.shutdown()
    }
}
