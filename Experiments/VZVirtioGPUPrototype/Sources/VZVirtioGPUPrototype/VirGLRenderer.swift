import CVirGLBridge
import Darwin
import Foundation
import Metal

final class VirGLRenderer {
    struct ScanoutTexture: Equatable {
        let id: UInt32
        let format: UInt32
        let width: UInt32
        let height: UInt32
        let stride: UInt32
    }
    struct ResourceArguments {
        let id: UInt32
        let target: UInt32
        let format: UInt32
        let bind: UInt32
        let width: UInt32
        let height: UInt32
        let depth: UInt32
        let arraySize: UInt32
        let lastLevel: UInt32
        let sampleCount: UInt32
        let flags: UInt32
    }

    struct Capset {
        let id: UInt32
        let maxVersion: UInt32
        let maxSize: UInt32
    }

    enum RendererError: Error, CustomStringConvertible {
        case load(String)
        case initialize(String)

        var description: String {
            switch self {
            case let .load(message): "could not load virglrenderer: \(message)"
            case let .initialize(message): "could not initialize virglrenderer: \(message)"
            }
        }
    }

    let libraryURL: URL
    let virglCapset: Capset
    private let executor: RendererExecutor

    init(libraryURL: URL) throws {
        self.libraryURL = libraryURL
        let executor = RendererExecutor()
        self.executor = executor
        let initialization = executor.sync { () -> (load: Int32, initialize: Int32, message: String, version: UInt32, size: UInt32) in
            let load = vzvg_renderer_load(libraryURL.path)
            guard load == 0 else { return (load, -1, Self.lastError, 0, 0) }
            let initialize = vzvg_renderer_initialize()
            guard initialize == 0 else { return (load, initialize, Self.lastError, 0, 0) }
            var version: UInt32 = 0
            var size: UInt32 = 0
            vzvg_renderer_get_cap_set(1, &version, &size)
            return (load, initialize, "", version, size)
        }
        guard initialization.load == 0 else {
            executor.stop()
            throw RendererError.load(initialization.message)
        }
        guard initialization.initialize == 0 else {
            executor.stop()
            throw RendererError.initialize(initialization.message)
        }
        let version = initialization.version
        let size = initialization.size
        guard version > 0, size > 0 else {
            vzvg_renderer_cleanup()
            throw RendererError.initialize("VirGL capset 1 is unavailable")
        }
        virglCapset = Capset(id: 1, maxVersion: version, maxSize: size)
        print(
            "[stage3] virglrenderer initialized: capset=1, "
                + "maxVersion=\(version), maxSize=\(size)"
        )
    }

    deinit {
        executor.sync { vzvg_renderer_cleanup() }
        executor.stop()
    }

    func capabilities(id: UInt32, version: UInt32) -> Data? {
        guard id == virglCapset.id,
              version <= virglCapset.maxVersion else { return nil }
        var data = Data(count: Int(virglCapset.maxSize))
        serialized {
            data.withUnsafeMutableBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    vzvg_renderer_fill_caps(id, version, baseAddress)
                }
            }
        }
        return data
    }

    func createResource(_ value: ResourceArguments) -> Bool {
        var arguments = vzvg_resource_create_args(
            handle: value.id, target: value.target, format: value.format,
            bind: value.bind, width: value.width, height: value.height,
            depth: value.depth, array_size: value.arraySize,
            last_level: value.lastLevel, nr_samples: value.sampleCount,
            flags: value.flags
        )
        return serialized { vzvg_renderer_resource_create(&arguments) == 0 }
    }

    func unrefResource(_ id: UInt32) { serialized { vzvg_renderer_resource_unref(id) } }

    func attach(resourceID: UInt32, iovecs: UnsafeMutablePointer<iovec>, count: Int) -> Bool {
        serialized { vzvg_renderer_resource_attach_iov(resourceID, iovecs, Int32(count)) == 0 }
    }

    func detach(resourceID: UInt32) {
        serialized { vzvg_renderer_resource_detach_iov(resourceID) }
    }

    func createContext(id: UInt32, name: String) -> Bool {
        serialized {
            name.withCString { pointer in
                vzvg_renderer_context_create(id, UInt32(name.utf8.count), pointer) == 0
            }
        }
    }

    func destroyContext(id: UInt32) { serialized { vzvg_renderer_context_destroy(id) } }
    func attach(contextID: UInt32, resourceID: UInt32) {
        serialized { vzvg_renderer_context_attach_resource(contextID, resourceID) }
    }
    func detach(contextID: UInt32, resourceID: UInt32) {
        serialized { vzvg_renderer_context_detach_resource(contextID, resourceID) }
    }

    func submit(contextID: UInt32, commands: Data) -> Bool {
        guard commands.count.isMultiple(of: 4) else { return false }
        var copy = commands
        return serialized {
            copy.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else { return false }
                return vzvg_renderer_submit(base, contextID, UInt32(commands.count / 4)) == 0
            }
        }
    }

    func transfer(
        resourceID: UInt32,
        contextID: UInt32,
        level: UInt32,
        stride: UInt32,
        layerStride: UInt32,
        box value: vzvg_box,
        offset: UInt64,
        backing: UnsafeMutablePointer<iovec>,
        count: Int,
        toHost: Bool
    ) -> Bool {
        var box = value
        return serialized {
            let result = toHost
                ? vzvg_renderer_transfer_write(
                    resourceID, contextID, level, stride, layerStride,
                    &box, offset, backing, Int32(count)
                )
                : vzvg_renderer_transfer_read(
                    resourceID, contextID, level, stride, layerStride,
                    &box, offset, backing, Int32(count)
                )
            return result == 0
        }
    }

    func waitForFence(_ fenceID: UInt32, contextID: UInt32) -> Bool {
        serialized {
            guard vzvg_renderer_create_fence(fenceID, contextID) == 0 else { return false }
            let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                vzvg_renderer_poll()
                var completed: UInt32 = 0
                while vzvg_renderer_pop_completed_fence(&completed) != 0 {
                    if completed == fenceID { return true }
                }
                usleep(100)
            }
            return false
        }
    }

    func borrowScanoutTexture(resourceID: UInt32) -> ScanoutTexture? {
        var info = vzvg_scanout_texture_info()
        guard serialized({ vzvg_renderer_borrow_scanout_texture(resourceID, &info) == 0 }),
              info.texture_id != 0 else { return nil }
        return ScanoutTexture(
            id: info.texture_id, format: info.format,
            width: info.width, height: info.height, stride: info.stride
        )
    }

    func present(
        resourceID: UInt32,
        into texture: any MTLTexture,
        width: UInt32,
        height: UInt32
    ) -> Bool {
        let pointer = Unmanaged.passUnretained(texture as AnyObject).toOpaque()
        return serialized {
            vzvg_renderer_present_scanout(resourceID, pointer, width, height) == 0
        }
    }

    private func serialized<T>(_ operation: @escaping () -> T) -> T {
        executor.sync(operation)
    }

    private static var lastError: String {
        guard let pointer = vzvg_renderer_last_error() else { return "unknown error" }
        return String(cString: pointer)
    }
}
