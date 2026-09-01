import CVirGLBridge
import Darwin
import Foundation
import Metal
import OSLog

final class VirGLRenderer {
    struct ScanoutDiagnostics: Sendable, Equatable {
        let signature: UInt64
        let generation: UInt64
    }
    typealias FenceCompletion = @Sendable (Bool) -> Void

    private struct PendingFence {
        let contextID: UInt32
        let deadline: UInt64
        let completion: FenceCompletion
    }

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
        case busy
        case libraryMismatch(URL, URL)

        var description: String {
            switch self {
            case let .load(message): "could not load virglrenderer: \(message)"
            case let .initialize(message): "could not initialize virglrenderer: \(message)"
            case .busy: "the process-global VirGL renderer is already in use by another VM"
            case let .libraryMismatch(loaded, requested):
                "the process-global VirGL renderer loaded \(loaded.path), not \(requested.path)"
            }
        }
    }

    private static let sharedLock = NSLock()
    private static var sharedRenderer: VirGLRenderer?
    private static var sharedRendererIsLeased = false

    /// virglrenderer and the ANGLE winsys are process-global. Keep their
    /// executor and GL root context alive across sequential VM sessions instead
    /// of calling renderer_init again, which the pinned renderer rejects.
    static func acquire(libraryURL: URL) throws -> VirGLRenderer {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let renderer = sharedRenderer {
            guard renderer.libraryURL.standardizedFileURL == libraryURL.standardizedFileURL else {
                throw RendererError.libraryMismatch(renderer.libraryURL, libraryURL)
            }
            guard !sharedRendererIsLeased else { throw RendererError.busy }
            sharedRendererIsLeased = true
            renderer.prepareForReuse()
            return renderer
        }
        let renderer = try VirGLRenderer(libraryURL: libraryURL)
        sharedRenderer = renderer
        sharedRendererIsLeased = true
        return renderer
    }

    let libraryURL: URL
    let virglCapset: Capset
    private let executor: RendererExecutor
    private let shutdownLock = NSLock()
    private var didShutdown = false
    private var nextHostFenceID: UInt32 = 1
    private var pendingFences: [UInt32: PendingFence] = [:]
    private var lastLoggedScanoutDiagnosticGeneration: UInt64 = 0
    private let logger = Logger(subsystem: "com.everettjf.ezvm", category: "virgl-fence")

    init(libraryURL: URL) throws {
        self.libraryURL = libraryURL
        let executor = RendererExecutor()
        self.executor = executor
        let initialization = executor.sync { () -> (load: Int32, initialize: Int32, message: String, version: UInt32, size: UInt32) in
            let load = vzvg_renderer_load(libraryURL.path)
            guard load == 0 else { return (load, -1, Self.lastError, 0, 0) }
            let initialize = vzvg_renderer_initialize()
            guard initialize == 0 else { return (load, initialize, Self.lastError, 0, 0) }
            vzvg_renderer_set_diagnostics_enabled(
                ProcessInfo.processInfo.environment["EZVM_VIRGL_DIAGNOSTICS"] == "1" ? 1 : 0
            )
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
        executor.configurePolling { [weak self] in
            self?.pollFences()
        }
        print(
            "[stage3] virglrenderer initialized: capset=1, "
                + "maxVersion=\(version), maxSize=\(size)"
        )
    }

    deinit { executor.stop() }

    func shutdown() {
        shutdownLock.lock()
        guard !didShutdown else {
            shutdownLock.unlock()
            return
        }
        didShutdown = true
        shutdownLock.unlock()
        cancelFences()
        // virglrenderer + the external ANGLE winsys are process-global. The
        // pinned stack does not support cleanup followed by initialization in
        // the same process (the second vrend_renderer_init returns EINVAL).
        // Device teardown has already destroyed every guest context/resource;
        // keep the empty global renderer initialized for the next VM window.
        // The OS reclaims the ANGLE display when EZVM exits.
        Self.sharedLock.lock()
        if Self.sharedRenderer === self {
            Self.sharedRendererIsLeased = false
        }
        Self.sharedLock.unlock()
    }

    private func prepareForReuse() {
        shutdownLock.lock()
        didShutdown = false
        shutdownLock.unlock()
        nextHostFenceID = 1
        pendingFences.removeAll(keepingCapacity: true)
        executor.configurePolling { [weak self] in self?.pollFences() }
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

    func enqueueFence(contextID: UInt32, completion: @escaping FenceCompletion) {
        executor.async { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            guard let hostFenceID = allocateHostFenceID() else {
                logger.error("could not allocate a host fence ID")
                completion(false)
                return
            }
            let createResult = vzvg_renderer_create_fence(hostFenceID, contextID)
            guard createResult == 0 else {
                logger.error(
                    "fence create failed: host=\(hostFenceID, privacy: .public) context=\(contextID, privacy: .public) result=\(createResult, privacy: .public) renderer=\(Self.lastError, privacy: .public)"
                )
                completion(false)
                return
            }
            pendingFences[hostFenceID] = PendingFence(
                contextID: contextID,
                deadline: DispatchTime.now().uptimeNanoseconds + 2_000_000_000,
                completion: completion
            )
            executor.setPollingEnabled(true)
        }
    }

    func cancelFences() {
        executor.sync {
            let completions = self.pendingFences.values.map(\.completion)
            self.pendingFences.removeAll()
            self.executor.setPollingEnabled(false)
            completions.forEach { $0(false) }
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
        sourceX: UInt32,
        sourceY: UInt32,
        sourceWidth: UInt32,
        sourceHeight: UInt32,
        width: UInt32,
        height: UInt32
    ) -> Bool {
        let pointer = Unmanaged.passUnretained(texture as AnyObject).toOpaque()
        return serialized {
            vzvg_renderer_present_scanout(
                resourceID, pointer, sourceX, sourceY, sourceWidth, sourceHeight, width, height
            ) == 0
        }
    }

    func presentAsync(
        resourceID: UInt32,
        into texture: any MTLTexture,
        sourceX: UInt32,
        sourceY: UInt32,
        sourceWidth: UInt32,
        sourceHeight: UInt32,
        width: UInt32,
        height: UInt32,
        completion: @escaping (Bool) -> Void
    ) {
        executor.async {
            let pointer = Unmanaged.passUnretained(texture as AnyObject).toOpaque()
            let result = vzvg_renderer_present_scanout(
                resourceID, pointer, sourceX, sourceY, sourceWidth, sourceHeight, width, height
            )
            if result != 0 {
                self.logger.error(
                    "scanout presentation failed: resource=\(resourceID, privacy: .public) source=\(width, privacy: .public)x\(height, privacy: .public) renderer=\(Self.lastError, privacy: .public)"
                )
            } else if ProcessInfo.processInfo.environment["EZVM_VIRGL_DIAGNOSTICS"] == "1" {
                let diagnostics = ScanoutDiagnostics(
                    signature: vzvg_renderer_scanout_signature(),
                    generation: vzvg_renderer_scanout_signature_generation()
                )
                if diagnostics.generation != 0,
                   diagnostics.generation != self.lastLoggedScanoutDiagnosticGeneration {
                    self.lastLoggedScanoutDiagnosticGeneration = diagnostics.generation
                    self.logger.info(
                        "scanout content changed: generation=\(diagnostics.generation, privacy: .public) signature=\(String(diagnostics.signature, radix: 16), privacy: .public)"
                    )
                    if let file = fopen("/tmp/ezvm-virgl-content.log", "a") {
                        fputs(
                            "resource=\(resourceID) size=\(width)x\(height) generation=\(diagnostics.generation) signature=\(String(diagnostics.signature, radix: 16))\n",
                            file
                        )
                        fclose(file)
                    }
                }
            }
            completion(result == 0)
        }
    }

    func scanoutDiagnostics() -> ScanoutDiagnostics {
        serialized {
            ScanoutDiagnostics(
                signature: vzvg_renderer_scanout_signature(),
                generation: vzvg_renderer_scanout_signature_generation()
            )
        }
    }

    private func serialized<T>(_ operation: @escaping () -> T) -> T {
        executor.sync(operation)
    }

    private func allocateHostFenceID() -> UInt32? {
        for _ in 0..<UInt64(UInt32.max) {
            let candidate = nextHostFenceID
            nextHostFenceID = nextHostFenceID == UInt32.max ? 1 : nextHostFenceID + 1
            if pendingFences[candidate] == nil { return candidate }
        }
        return nil
    }

    private func pollFences() {
        guard !pendingFences.isEmpty else {
            executor.setPollingEnabled(false)
            return
        }
        vzvg_renderer_poll()
        var completions: [(FenceCompletion, Bool)] = []
        var completedID: UInt32 = 0
        while vzvg_renderer_pop_completed_fence(&completedID) != 0 {
            if let fence = pendingFences.removeValue(forKey: completedID) {
                logger.debug(
                    "fence completed: host=\(completedID, privacy: .public) context=\(fence.contextID, privacy: .public)"
                )
                completions.append((fence.completion, true))
            } else {
                logger.error("unknown fence completion: host=\(completedID, privacy: .public)")
            }
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let expired = pendingFences.compactMap { id, fence in
            fence.deadline <= now ? id : nil
        }
        for id in expired {
            if let fence = pendingFences.removeValue(forKey: id) {
                logger.error(
                    "fence timed out: host=\(id, privacy: .public) context=\(fence.contextID, privacy: .public)"
                )
                completions.append((fence.completion, false))
            }
        }
        if pendingFences.isEmpty { executor.setPollingEnabled(false) }
        completions.forEach { completion, succeeded in completion(succeeded) }
    }

    private static var lastError: String {
        guard let pointer = vzvg_renderer_last_error() else { return "unknown error" }
        return String(cString: pointer)
    }
}
