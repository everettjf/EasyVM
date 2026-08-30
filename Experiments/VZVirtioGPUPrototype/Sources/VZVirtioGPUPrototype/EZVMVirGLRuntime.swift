import CoreGraphics
import Foundation
import Metal
@preconcurrency import Virtualization

/// Production-facing owner for the custom Virtio GPU, VirGL renderer, and
/// ANGLE/Metal presentation path. The command-line prototype is now only a
/// client of this API.
@available(macOS 27.0, *)
public final class EZVMVirGLRuntime: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var width: UInt32
        public var height: UInt32
        public var rendererLibraryURL: URL
        public var zeroCopyPresentationEnabled: Bool

        public init(
            width: UInt32,
            height: UInt32,
            rendererLibraryURL: URL,
            zeroCopyPresentationEnabled: Bool = true
        ) {
            self.width = width
            self.height = height
            self.rendererLibraryURL = rendererLibraryURL
            self.zeroCopyPresentationEnabled = zeroCopyPresentationEnabled
        }
    }

    public enum RuntimeError: Error, CustomStringConvertible {
        case renderer(String)
        case stopped

        public var description: String {
            switch self {
            case let .renderer(message): message
            case .stopped: "The VirGL runtime has already stopped."
            }
        }
    }

    private let stateLock = NSLock()
    private var renderer: VirGLRenderer?
    private var gpuDevice: VirtioGPUDevice?

    public init(
        configuration: Configuration,
        onScanout: @escaping @MainActor @Sendable (UInt32) -> Void,
        onFallbackFrame: @escaping @MainActor @Sendable (CGImage) -> Void = { _ in }
    ) throws {
        do {
            let renderer = try VirGLRenderer(libraryURL: configuration.rendererLibraryURL)
            self.renderer = renderer
            gpuDevice = VirtioGPUDevice(
                width: configuration.width,
                height: configuration.height,
                renderer: renderer,
                zeroCopyPresentationEnabled: configuration.zeroCopyPresentationEnabled,
                onZeroCopyFrame: onScanout,
                onFrame: onFallbackFrame
            )
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

    public func present(
        resourceID: UInt32,
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
            width: UInt32(texture.width),
            height: UInt32(texture.height)
        )
    }

    /// Deterministic teardown for VM stop, failed startup, and window close.
    /// Dropping the device first releases all renderer-backed guest resources;
    /// dropping the renderer then cleans ANGLE/VirGL on its dedicated thread.
    public func shutdown() {
        stateLock.lock()
        gpuDevice = nil
        renderer = nil
        stateLock.unlock()
    }
}
