import AppKit
import CVirGLBridge
import Darwin
import Foundation
import ImageIO
import OSLog
import Virtualization

@available(macOS 27.0, *)
final class VirtioGPUDevice: NSObject, @unchecked Sendable,
    VZCustomVirtioDeviceConfigurationDelegate,
    VZCustomVirtioDeviceDelegate
{
    private final class QueueElementLease: @unchecked Sendable {
        let element: VZVirtioQueueElement

        init(_ element: VZVirtioQueueElement) {
            self.element = element
        }
    }

    struct BackingEntry {
        let mapping: VZGuestMemoryMapping
        let length: Int
    }

    final class VirGLBacking {
        let entries: [BackingEntry]
        let iovecs: UnsafeMutablePointer<iovec>

        init(entries: [BackingEntry]) {
            self.entries = entries
            iovecs = .allocate(capacity: entries.count)
            for (index, entry) in entries.enumerated() {
                iovecs[index] = iovec(iov_base: entry.mapping.mutableBytes, iov_len: entry.length)
            }
        }

        deinit { iovecs.deallocate() }
    }

    struct Resource {
        let id: UInt32
        let format: UInt32
        let width: Int
        let height: Int
        var backing: [BackingEntry] = []
        var virglBacking: VirGLBacking?
        var isRendererResource = false
        var pixels = Data()
    }

    private var width: UInt32
    private var height: UInt32
    let renderer: VirGLRenderer
    let onFrame: @MainActor (CGImage) -> Void
    struct ScanoutFrame: Sendable {
        let resourceID: UInt32
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    let onZeroCopyFrame: @MainActor (ScanoutFrame) -> Void
    let onScanoutInvalidated: @MainActor () -> Void
    let onCursor: @MainActor (EZVMVirGLRuntime.CursorUpdate) -> Void
    let zeroCopyPresentationEnabled: Bool
    let deviceQueue = DispatchQueue(label: "com.everettjf.ezvm.prototype.virtio-gpu")

    private(set) var device: VZCustomVirtioDevice?
    private var resources: [UInt32: Resource] = [:]
    private var totalPixelBytes = 0
    private var contexts: Set<UInt32> = []
    private var contextResources: [UInt32: Set<UInt32>] = [:]
    private var scanoutResourceID: UInt32?
    private var scanoutRect: VirtioGPU.Rect?
    private var lastPublishedScanoutResourceID: UInt32?
    private var lastLoggedScanoutSize: (width: Int, height: Int)?
    private var cursorResourceID: UInt32?
    private var cursorPosition = VirtioGPU.CursorPosition(
        scanoutID: 0, x: 0, y: 0
    )
    private var publishedFrameCount = 0
    private var submittedCommandCount = 0
    private var resourceFlushCount: UInt64 = 0
    private var diagnosticWindowStartedAt = CFAbsoluteTimeGetCurrent()
    private var diagnosticWindowSubmitCount = 0
    private var diagnosticWindowFlushCount: UInt64 = 0
    private var cursorUpdateCount = 0
    private var cursorMoveCount = 0
    private var displayEventGeneration = 0
    private var assertedDisplayEventGeneration: Int?
    private var displayInfoRequestCount: UInt64 = 0
    private var borrowedScanoutResources: Set<UInt32> = []
    private var savedEvidenceFrame = false
    private lazy var frameScheduler = LatestFrameScheduler<ScanoutFrame> { [weak self] frame, completed in
        guard let self else {
            completed()
            return
        }
        Task { @MainActor [onZeroCopyFrame] in
            onZeroCopyFrame(frame)
            self.deviceQueue.async { completed() }
        }
    }

    init(
        width: UInt32,
        height: UInt32,
        renderer: VirGLRenderer,
        zeroCopyPresentationEnabled: Bool = true,
        onZeroCopyFrame: @escaping @MainActor (ScanoutFrame) -> Void,
        onScanoutInvalidated: @escaping @MainActor () -> Void = {},
        onCursor: @escaping @MainActor (EZVMVirGLRuntime.CursorUpdate) -> Void = { _ in },
        onFrame: @escaping @MainActor (CGImage) -> Void
    ) {
        self.width = width
        self.height = height
        self.renderer = renderer
        self.zeroCopyPresentationEnabled = zeroCopyPresentationEnabled
        self.onZeroCopyFrame = onZeroCopyFrame
        self.onScanoutInvalidated = onScanoutInvalidated
        self.onCursor = onCursor
        self.onFrame = onFrame
    }

    func makeConfiguration() -> VZCustomVirtioDeviceConfiguration {
        let configuration = VZCustomVirtioDeviceConfiguration()
        configuration.deviceID = VirtioGPU.deviceID
        configuration.pciClassID = VirtioGPU.pciDisplayClass
        configuration.pciSubclassID = VirtioGPU.pciOtherDisplaySubclass
        configuration.virtioQueueCount = VirtioGPU.queueCount
        // VIRTIO_GPU_F_VIRGL is bit 0 and VIRTIO_GPU_F_EDID is bit 1.
        configuration.optionalFeatures.subset0 = 3

        // struct virtio_gpu_config: events_read, events_clear, num_scanouts,
        // num_capsets. Stage 3 exposes the VirGL capset.
        configuration.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(
            configurationData: VirtioGPU.deviceConfigurationData(displayEvent: false)
        )
        configuration.provider = VZCustomVirtioDeviceDelegateProvider(
            deviceQueue: deviceQueue,
            delegate: self
        )
        return configuration
    }

    func requestDisplaySize(width: UInt32, height: UInt32) {
        let requested = VirtioGPU.clampedDisplaySize(width: width, height: height)
        let requestedWidth = requested.width
        let requestedHeight = requested.height
        deviceQueue.async { [weak self] in
            guard let self,
                  self.width != requestedWidth || self.height != requestedHeight else { return }
            self.width = requestedWidth
            self.height = requestedHeight
            self.displayEventGeneration &+= 1
            let generation = self.displayEventGeneration
            self.assertedDisplayEventGeneration = generation
            self.log("publishing display configuration generation=\(generation) size=\(requestedWidth)x\(requestedHeight)")
            guard let device = self.device else { return }
            let changed = VZVirtioDeviceSpecificConfiguration(
                configurationData: VirtioGPU.deviceConfigurationData(displayEvent: true)
            )
            device.update(changed) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.log("display configuration generation=\(generation) failed: \(error.localizedDescription)", error: true)
                    return
                }
                self.log("display configuration generation=\(generation) interrupt delivered")
            }
        }
    }

    private func clearDisplayEventAfterGuestRead() {
        guard let generation = assertedDisplayEventGeneration,
              generation == displayEventGeneration,
              let device else { return }
        assertedDisplayEventGeneration = nil
        let cleared = VZVirtioDeviceSpecificConfiguration(
            configurationData: VirtioGPU.deviceConfigurationData(displayEvent: false)
        )
        device.update(cleared) { [weak self] error in
            if let error {
                self?.log("display configuration generation=\(generation) clear failed: \(error.localizedDescription)", error: true)
            } else {
                self?.log("display configuration generation=\(generation) acknowledged by guest and cleared")
            }
        }
    }

    private let logger = Logger(subsystem: "com.everettjf.EZVM", category: "virtio-gpu")

    private var diagnosticsEnabled: Bool {
        ProcessInfo.processInfo.environment["EZVM_VIRGL_DIAGNOSTICS"] == "1"
    }

    private func log(_ message: String, error: Bool = false) {
        if error {
            logger.error("\(message, privacy: .public)")
        } else {
            logger.info("\(message, privacy: .public)")
        }
        if diagnosticsEnabled {
            let line = "[virtio-gpu] \(message)\n"
            fputs(line, stderr)
            fflush(stderr)
            if let file = fopen("/tmp/ezvm-virtio-gpu.log", "a") {
                fputs(line, file)
                fclose(file)
            }
        }
    }

    private func diagnosticLog(_ message: String) {
        guard diagnosticsEnabled else { return }
        log(message)
    }

    private func recordDiagnosticsIfNeeded(trigger: String) {
        guard ProcessInfo.processInfo.environment["EZVM_VIRGL_DIAGNOSTICS"] == "1" else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - diagnosticWindowStartedAt >= 1 else { return }
        log(
            "render activity trigger=\(trigger) submits=\(diagnosticWindowSubmitCount) "
                + "flushes=\(diagnosticWindowFlushCount) totalSubmits=\(submittedCommandCount) "
                + "totalFlushes=\(resourceFlushCount) scanout=\(scanoutResourceID ?? 0)"
        )
        diagnosticWindowStartedAt = now
        diagnosticWindowSubmitCount = 0
        diagnosticWindowFlushCount = 0
    }

    func customVirtioConfiguration(
        _ deviceConfiguration: VZCustomVirtioDeviceConfiguration,
        didCreateDevice device: VZCustomVirtioDevice
    ) {
        self.device = device
        device.delegate = self
        print("[stage1] Virtualization created custom virtio device id=\(deviceConfiguration.deviceID)")
    }

    func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        print("[stage1] Linux driver accepted DRIVER_OK; standard virtio-gpu identity is viable")
        print("[stage1] queues: control=\(device.queue(at: 0) != nil), cursor=\(device.queue(at: 1) != nil)")
    }

    func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) {
        releaseDeviceState(reason: "stop")
    }

    func customVirtioDeviceWillPause(_ device: VZCustomVirtioDevice) {
        // Presentation callbacks are host UI work and must not outlive the
        // point at which Virtualization has paused the device. Renderer and
        // guest resource state remain intact for resume.
        frameScheduler.cancel()
        print("[stage6] custom Virtio GPU paused")
    }

    func customVirtioDeviceWillResume(_ device: VZCustomVirtioDevice) {
        print("[stage6] custom Virtio GPU resumed")
    }

    func customVirtioDevice(
        _ device: VZCustomVirtioDevice,
        didReceiveNotificationFor queue: VZVirtioQueue
    ) {
        while let element = queue.nextElement() {
            let returnSynchronously = autoreleasepool {
                process(element: element, queueIndex: queue.queueIndex, device: device)
            }
            if returnSynchronously { element.returnToQueue() }
        }
    }

    func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        releaseDeviceState(reason: "reset")
    }

    private func releaseDeviceState(reason: String) {
        frameScheduler.cancel()
        Task { @MainActor [onScanoutInvalidated] in onScanoutInvalidated() }
        renderer.cancelFences()
        for contextID in contexts { renderer.destroyContext(id: contextID) }
        for resource in resources.values where resource.isRendererResource {
            if resource.virglBacking != nil { renderer.detach(resourceID: resource.id) }
            renderer.unrefResource(resource.id)
        }
        resources.removeAll()
        totalPixelBytes = 0
        contexts.removeAll()
        contextResources.removeAll()
        scanoutResourceID = nil
        lastPublishedScanoutResourceID = nil
        lastLoggedScanoutSize = nil
        cursorResourceID = nil
        borrowedScanoutResources.removeAll()
        publishCursor(image: nil, hotX: 0, hotY: 0)
        print("[stage6] released custom Virtio GPU state for \(reason)")
    }

    private func process(
        element: VZVirtioQueueElement,
        queueIndex: UInt16,
        device: VZCustomVirtioDevice
    ) -> Bool {
        var request = Data()
        for buffer in element.readBuffers() {
            guard buffer.count <= VirtioGPU.Limits.maxRequestBytes - request.count else {
                if let header = VirtioGPU.Header(request) {
                    write(VirtioGPU.responseHeader(.errorInvalidParameter, request: header), to: element)
                }
                print("[gpu] rejected oversized request on queue \(queueIndex)")
                return true
            }
            request.append(buffer)
        }
        guard let header = VirtioGPU.Header(request) else {
            print("[gpu] short request on queue \(queueIndex): \(request.count) bytes")
            return true
        }

        guard let command = VirtioGPU.Command(rawValue: header.type) else {
            print(String(format: "[gpu] unsupported command 0x%04x", header.type))
            write(VirtioGPU.responseHeader(.errorUnspecified, request: header), to: element)
            return true
        }
        guard VirtioGPU.command(command, isValidOn: queueIndex) else {
            print("[gpu] command \(command) arrived on invalid queue \(queueIndex)")
            write(VirtioGPU.responseHeader(.errorInvalidParameter, request: header), to: element)
            return true
        }

        let response: Data
        switch command {
        case .getDisplayInfo:
            displayInfoRequestCount &+= 1
            log("guest GET_DISPLAY_INFO request=\(displayInfoRequestCount) generation=\(displayEventGeneration) size=\(width)x\(height)")
            response = VirtioGPU.displayInfoResponse(request: header, width: width, height: height)
            clearDisplayEventAfterGuestRead()

        case .getCapsetInfo:
            response = getCapsetInfo(request, header: header)

        case .getCapset:
            response = getCapset(request, header: header)

        case .resourceCreate2D:
            response = create2D(request, header: header)

        case .resourceUnref:
            guard request.count >= 32 else {
                response = VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
                break
            }
            let resourceID = request.littleEndianUInt32(at: 24)
            guard let resource = resources[resourceID] else {
                response = VirtioGPU.responseHeader(.errorInvalidResourceID, request: header)
                break
            }
            diagnosticLog(
                "RESOURCE_UNREF resource=\(resourceID) contexts="
                    + contextResources.compactMap { contextID, resourceIDs in
                        resourceIDs.contains(resourceID) ? String(contextID) : nil
                    }.sorted().joined(separator: ",")
            )
            // virglrenderer keeps a per-context resource table in addition to
            // its global resource table. RESOURCE_UNREF can legally arrive
            // without a preceding CTX_DETACH_RESOURCE; dropping only the global
            // object leaves a stale context entry, and the next DRAW_VBO poisons
            // the compositor context with "Illegal resource". Detach exactly the
            // memberships still tracked here before removing the global object.
            for contextID in contexts {
                if contextResources[contextID]?.remove(resourceID) != nil {
                    renderer.detach(contextID: contextID, resourceID: resourceID)
                }
            }
            if resource.isRendererResource {
                if resource.virglBacking != nil { renderer.detach(resourceID: resourceID) }
                renderer.unrefResource(resourceID)
            }
            resources.removeValue(forKey: resourceID)
            totalPixelBytes -= resource.pixels.count
            let wasActiveScanout = scanoutResourceID == resourceID
            let wasPublishedScanout = lastPublishedScanoutResourceID == resourceID
            if wasActiveScanout {
                scanoutResourceID = nil
                scanoutRect = nil
            }
            if borrowedScanoutResources.contains(resourceID) {
                frameScheduler.cancel()
                if wasPublishedScanout {
                    lastPublishedScanoutResourceID = nil
                }
                diagnosticLog(
                    "scanout resource=\(resourceID) was released "
                        + "active=\(wasActiveScanout) published=\(wasPublishedScanout)"
                )
            }
            borrowedScanoutResources.remove(resourceID)
            if cursorResourceID == resourceID {
                cursorResourceID = nil
                publishCursor(image: nil, hotX: 0, hotY: 0)
            }
            response = VirtioGPU.responseHeader(.okNoData, request: header)

        case .resourceAttachBacking:
            response = attachBacking(request, header: header, device: device)

        case .resourceDetachBacking:
            let resourceID = request.littleEndianUInt32(at: 24)
            guard var resource = resources[resourceID] else {
                response = VirtioGPU.responseHeader(.errorInvalidResourceID, request: header)
                break
            }
            if resource.isRendererResource { renderer.detach(resourceID: resourceID) }
            resource.backing.removeAll()
            resource.virglBacking = nil
            resources[resourceID] = resource
            if cursorResourceID == resourceID {
                cursorResourceID = nil
                publishCursor(image: nil, hotX: 0, hotY: 0)
            }
            response = VirtioGPU.responseHeader(.okNoData, request: header)

        case .setScanout:
            response = setScanout(request, header: header)

        case .transferToHost2D:
            response = transferToHost(request, header: header)

        case .resourceFlush:
            response = flush(request, header: header)

        case .getEDID:
            guard request.count >= 32 else {
                response = VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
                break
            }
            let scanoutID = request.littleEndianUInt32(at: 24)
            guard scanoutID == 0 else {
                response = VirtioGPU.responseHeader(.errorInvalidScanoutID, request: header)
                break
            }
            log("guest GET_EDID generation=\(displayEventGeneration) size=\(width)x\(height)")
            response = VirtioGPU.edidResponse(request: header, width: width, height: height)

        case .contextCreate:
            response = createContext(request, header: header)

        case .contextDestroy:
            guard request.count >= 24, header.contextID != 0, contexts.remove(header.contextID) != nil else {
                response = VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
                break
            }
            diagnosticLog(
                "CTX_DESTROY context=\(header.contextID) resources="
                    + (contextResources[header.contextID] ?? []).sorted().map(String.init).joined(separator: ",")
            )
            renderer.destroyContext(id: header.contextID)
            contextResources.removeValue(forKey: header.contextID)
            response = VirtioGPU.responseHeader(.okNoData, request: header)

        case .contextAttachResource:
            response = contextResource(request, header: header, attach: true)

        case .contextDetachResource:
            response = contextResource(request, header: header, attach: false)

        case .submit3D:
            response = submit3D(request, header: header)

        case .resourceCreate3D:
            response = create3D(request, header: header)

        case .transferToHost3D:
            response = transfer3D(request, header: header, toHost: true)

        case .transferFromHost3D:
            response = transfer3D(request, header: header, toHost: false)

        case .updateCursor:
            response = updateCursor(request, header: header)

        case .moveCursor:
            response = moveCursor(request, header: header)
        }
        guard header.flags & VirtioGPU.flagFence != 0 else {
            write(response, to: element)
            return true
        }
        let completionQueue = deviceQueue
        let elementLease = QueueElementLease(element)
        renderer.enqueueFence(contextID: header.contextID) { [weak self] succeeded in
            completionQueue.async {
                if let self {
                    let finalResponse = succeeded
                        ? response
                        : VirtioGPU.responseHeader(.errorUnspecified, request: header)
                    self.write(finalResponse, to: elementLease.element)
                }
                elementLease.element.returnToQueue()
            }
        }
        return false
    }

    private func getCapsetInfo(_ request: Data, header: VirtioGPU.Header) -> Data {
        guard request.count >= 32 else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        let index = request.littleEndianUInt32(at: 24)
        guard index == 0 else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        let capset = renderer.virglCapset
        var response = VirtioGPU.responseHeader(.okCapsetInfo, request: header)
        response.appendLittleEndian(capset.id)
        response.appendLittleEndian(capset.maxVersion)
        response.appendLittleEndian(capset.maxSize)
        response.appendLittleEndian(UInt32(0))
        print(
            "[stage3] guest requested VirGL capset info: "
                + "version=\(capset.maxVersion), size=\(capset.maxSize)"
        )
        return response
    }

    private func getCapset(_ request: Data, header: VirtioGPU.Header) -> Data {
        guard request.count >= 32 else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        let id = request.littleEndianUInt32(at: 24)
        let version = request.littleEndianUInt32(at: 28)
        print("[stage3] guest requested capset \(id), version \(version)")
        guard let capabilities = renderer.capabilities(id: id, version: version) else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        var response = VirtioGPU.responseHeader(.okCapset, request: header)
        response.append(capabilities)
        print("[stage3] delivered VirGL capset \(id), version \(version)")
        return response
    }

    private func create2D(_ request: Data, header: VirtioGPU.Header) -> Data {
        guard request.count >= 40 else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        let resourceID = request.littleEndianUInt32(at: 24)
        let format = request.littleEndianUInt32(at: 28)
        let wireWidth = request.littleEndianUInt32(at: 32)
        let wireHeight = request.littleEndianUInt32(at: 36)
        guard resourceID != 0, resources[resourceID] == nil,
              resources.count < VirtioGPU.Limits.maxResources,
              let byteCount = VirtioGPU.pixelByteCount(width: wireWidth, height: wireHeight),
              totalPixelBytes <= VirtioGPU.Limits.maxTotalPixelBytes - byteCount else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        let width = Int(wireWidth)
        let height = Int(wireHeight)
        var resource = Resource(
            id: resourceID,
            format: format,
            width: width,
            height: height,
            pixels: Data(count: byteCount)
        )
        resource.isRendererResource = renderer.createResource(.init(
            id: resourceID, target: 2, format: format, bind: 2,
            width: UInt32(width), height: UInt32(height), depth: 1,
            arraySize: 1, lastLevel: 0, sampleCount: 0, flags: 0
        ))
        guard resource.isRendererResource else {
            return VirtioGPU.responseHeader(.errorOutOfMemory, request: header)
        }
        resources[resourceID] = resource
        totalPixelBytes += byteCount
        print("[stage2] create 2D resource \(resourceID): \(width)x\(height), format=\(format)")
        return VirtioGPU.responseHeader(.okNoData, request: header)
    }

    private func create3D(_ request: Data, header: VirtioGPU.Header) -> Data {
        guard request.count >= 72 else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        let resourceID = request.littleEndianUInt32(at: 24)
        let width = request.littleEndianUInt32(at: 40)
        let height = request.littleEndianUInt32(at: 44)
        let depth = request.littleEndianUInt32(at: 48)
        let arraySize = request.littleEndianUInt32(at: 52)
        let lastLevel = request.littleEndianUInt32(at: 56)
        let sampleCount = request.littleEndianUInt32(at: 60)
        let target = request.littleEndianUInt32(at: 28)
        let hasValidDimensions = VirtioGPU.valid3DResourceDimensions(
                target: target,
                width: width, height: height, depth: depth, arraySize: arraySize,
                lastLevel: lastLevel, sampleCount: sampleCount
              )
        guard resourceID != 0, resources[resourceID] == nil,
              resources.count < VirtioGPU.Limits.maxResources,
              hasValidDimensions else {
            log(
                "RESOURCE_CREATE_3D rejected-before-renderer resource=\(resourceID) "
                    + "target=\(target) "
                    + "format=\(request.littleEndianUInt32(at: 32)) "
                    + "bind=\(request.littleEndianUInt32(at: 36)) "
                    + "size=\(width)x\(height)x\(depth) array=\(arraySize) "
                    + "levels=\(lastLevel) samples=\(sampleCount) "
                    + "flags=\(request.littleEndianUInt32(at: 64)) "
                    + "duplicate=\(resources[resourceID] != nil) "
                    + "resourceCount=\(resources.count) dimensionsValid=\(hasValidDimensions)",
                error: true
            )
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        let arguments = VirGLRenderer.ResourceArguments(
            id: resourceID,
            target: target,
            format: request.littleEndianUInt32(at: 32),
            bind: request.littleEndianUInt32(at: 36),
            width: width,
            height: height,
            depth: depth,
            arraySize: arraySize,
            lastLevel: lastLevel,
            sampleCount: sampleCount,
            flags: request.littleEndianUInt32(at: 64)
        )
        guard renderer.createResource(arguments) else {
            print(
                "[stage3] rejected 3D resource \(resourceID): "
                + "target=\(arguments.target), format=\(arguments.format), bind=\(arguments.bind), "
                + "size=\(width)x\(height)x\(depth), array=\(arraySize), levels=\(lastLevel), "
                + "samples=\(sampleCount), flags=\(arguments.flags)"
            )
            return VirtioGPU.responseHeader(.errorOutOfMemory, request: header)
        }
        resources[resourceID] = Resource(
            id: resourceID, format: arguments.format,
            width: Int(width), height: Int(height),
            isRendererResource: true
        )
        diagnosticLog(
            "RESOURCE_CREATE_3D resource=\(resourceID) target=\(arguments.target) "
                + "format=\(arguments.format) bind=\(arguments.bind) size=\(width)x\(height)x\(depth)"
        )
        return VirtioGPU.responseHeader(.okNoData, request: header)
    }

    private func attachBacking(
        _ request: Data,
        header: VirtioGPU.Header,
        device: VZCustomVirtioDevice
    ) -> Data {
        guard request.count >= 32 else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        let resourceID = request.littleEndianUInt32(at: 24)
        let entryCount = Int(request.littleEndianUInt32(at: 28))
        guard var resource = resources[resourceID] else {
            return VirtioGPU.responseHeader(.errorInvalidResourceID, request: header)
        }
        guard resource.virglBacking == nil,
              entryCount > 0, entryCount <= VirtioGPU.Limits.maxBackingEntries,
              request.count >= 32 + entryCount * 16 else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }

        var entries: [BackingEntry] = []
        entries.reserveCapacity(entryCount)
        var totalBackingBytes = 0
        for index in 0..<entryCount {
            let offset = 32 + index * 16
            let address = request.littleEndianUInt64(at: offset)
            let length = Int(request.littleEndianUInt32(at: offset + 8))
            guard length > 0, length <= VirtioGPU.Limits.maxBackingBytes - totalBackingBytes,
                  let mapping = device.guestMemoryMapping(atPhysicalAddress: address, length: length) else {
                return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
            }
            entries.append(BackingEntry(mapping: mapping, length: length))
            totalBackingBytes += length
        }
        resource.backing = entries
        let virglBacking = VirGLBacking(entries: entries)
        guard !resource.isRendererResource
                || renderer.attach(resourceID: resourceID, iovecs: virglBacking.iovecs, count: entries.count) else {
            return VirtioGPU.responseHeader(.errorUnspecified, request: header)
        }
        resource.virglBacking = virglBacking
        resources[resourceID] = resource
        return VirtioGPU.responseHeader(.okNoData, request: header)
    }

    private func createContext(_ request: Data, header: VirtioGPU.Header) -> Data {
        guard request.count >= 96, header.contextID != 0, !contexts.contains(header.contextID) else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        let nameLength = min(Int(request.littleEndianUInt32(at: 24)), 64)
        let nameBytes = request[32..<(32 + nameLength)]
        let name = String(decoding: nameBytes, as: UTF8.self)
        guard renderer.createContext(id: header.contextID, name: name) else {
            return VirtioGPU.responseHeader(.errorUnspecified, request: header)
        }
        contexts.insert(header.contextID)
        contextResources[header.contextID] = []
        print("[stage3] created VirGL context \(header.contextID): \(name)")
        return VirtioGPU.responseHeader(.okNoData, request: header)
    }

    private func contextResource(
        _ request: Data,
        header: VirtioGPU.Header,
        attach: Bool
    ) -> Data {
        guard request.count >= 32, contexts.contains(header.contextID) else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        let resourceID = request.littleEndianUInt32(at: 24)
        guard resources[resourceID]?.isRendererResource == true else {
            return VirtioGPU.responseHeader(.errorInvalidResourceID, request: header)
        }
        if attach {
            if contextResources[header.contextID]?.insert(resourceID).inserted == true {
                diagnosticLog("CTX_ATTACH_RESOURCE context=\(header.contextID) resource=\(resourceID)")
                renderer.attach(contextID: header.contextID, resourceID: resourceID)
            }
        } else {
            guard contextResources[header.contextID]?.remove(resourceID) != nil else {
                return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
            }
            diagnosticLog("CTX_DETACH_RESOURCE context=\(header.contextID) resource=\(resourceID)")
            renderer.detach(contextID: header.contextID, resourceID: resourceID)
        }
        return VirtioGPU.responseHeader(.okNoData, request: header)
    }

    private func submit3D(_ request: Data, header: VirtioGPU.Header) -> Data {
        guard request.count >= 32 else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        let byteCount = Int(request.littleEndianUInt32(at: 24))
        guard contexts.contains(header.contextID),
              byteCount > 0, byteCount <= VirtioGPU.Limits.maxSubmitBytes,
              byteCount.isMultiple(of: 4), request.count >= 32 + byteCount else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        let commands = Data(request[32..<(32 + byteCount)])
        guard renderer.submit(contextID: header.contextID, commands: commands) else {
            return VirtioGPU.responseHeader(.errorUnspecified, request: header)
        }
        submittedCommandCount += 1
        diagnosticWindowSubmitCount += 1
        recordDiagnosticsIfNeeded(trigger: "submit")
        if submittedCommandCount <= 10 || submittedCommandCount.isMultiple(of: 500) {
            print("[stage3] submitted command \(submittedCommandCount): \(byteCount) bytes, context \(header.contextID)")
        }
        return VirtioGPU.responseHeader(.okNoData, request: header)
    }

    private func transfer3D(
        _ request: Data,
        header: VirtioGPU.Header,
        toHost: Bool
    ) -> Data {
        guard request.count >= 72 else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        let resourceID = request.littleEndianUInt32(at: 56)
        guard let resource = resources[resourceID], let backing = resource.virglBacking else {
            return VirtioGPU.responseHeader(.errorInvalidResourceID, request: header)
        }
        let box = vzvg_box(
            x: request.littleEndianUInt32(at: 24),
            y: request.littleEndianUInt32(at: 28),
            z: request.littleEndianUInt32(at: 32),
            w: request.littleEndianUInt32(at: 36),
            h: request.littleEndianUInt32(at: 40),
            d: request.littleEndianUInt32(at: 44)
        )
        guard renderer.transfer(
            resourceID: resourceID,
            contextID: header.contextID,
            level: request.littleEndianUInt32(at: 60),
            stride: request.littleEndianUInt32(at: 64),
            layerStride: request.littleEndianUInt32(at: 68),
            box: box,
            offset: request.littleEndianUInt64(at: 48),
            backing: backing.iovecs,
            count: backing.entries.count,
            toHost: toHost
        ) else {
            return VirtioGPU.responseHeader(.errorUnspecified, request: header)
        }
        return VirtioGPU.responseHeader(.okNoData, request: header)
    }

    private func setScanout(_ request: Data, header: VirtioGPU.Header) -> Data {
        guard request.count >= 48 else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        let scanoutID = request.littleEndianUInt32(at: 40)
        let resourceID = request.littleEndianUInt32(at: 44)
        guard scanoutID == 0 else {
            return VirtioGPU.responseHeader(.errorInvalidScanoutID, request: header)
        }
        if resourceID == 0 {
            scanoutResourceID = nil
            scanoutRect = nil
            lastPublishedScanoutResourceID = nil
            frameScheduler.cancel()
            // Linux temporarily disables and releases the old scanout while
            // applying a hot-plug mode.  Clearing the host layer here exposes
            // a black frame for the entire compositor rebuild (and, if the
            // guest misses a flush, indefinitely).  Preserve the last
            // successfully presented drawable until a new scanout flush
            // replaces it.  Device reset/shutdown still invalidates it via
            // releaseDeviceState().
            log("guest disabled scanout 0")
            return VirtioGPU.responseHeader(.okNoData, request: header)
        }
        guard resources[resourceID] != nil else {
            return VirtioGPU.responseHeader(.errorInvalidResourceID, request: header)
        }
        let rect = VirtioGPU.Rect(request, at: 24)
        guard let resource = resources[resourceID],
              VirtioGPU.rectIsContained(
                rect,
                resourceWidth: resource.width,
                resourceHeight: resource.height
              ) else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        scanoutResourceID = resourceID
        scanoutRect = rect
        let size = (width: Int(rect.width), height: Int(rect.height))
        if lastLoggedScanoutSize?.width != size.width || lastLoggedScanoutSize?.height != size.height {
            lastLoggedScanoutSize = size
            log(
                "guest scanout 0 rect=\(rect.x),\(rect.y) \(rect.width)x\(rect.height) "
                    + "resource=\(resourceID) texture=\(resource.width)x\(resource.height)"
            )
        }
        if lastPublishedScanoutResourceID != resourceID {
            diagnosticLog("scanout 0 now uses resource \(resourceID)")
        }
        return VirtioGPU.responseHeader(.okNoData, request: header)
    }

    private func updateCursor(_ request: Data, header: VirtioGPU.Header) -> Data {
        guard let update = VirtioGPU.CursorUpdate(request) else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        guard update.position.scanoutID == 0 else {
            return VirtioGPU.responseHeader(.errorInvalidScanoutID, request: header)
        }
        cursorPosition = update.position
        guard update.resourceID != 0 else {
            cursorResourceID = nil
            publishCursor(image: nil, hotX: update.hotX, hotY: update.hotY)
            return VirtioGPU.responseHeader(.okNoData, request: header)
        }
        guard var resource = resources[update.resourceID], !resource.backing.isEmpty else {
            return VirtioGPU.responseHeader(.errorInvalidResourceID, request: header)
        }
        guard update.hotX < UInt32(resource.width), update.hotY < UInt32(resource.height) else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        if resource.isRendererResource, let backing = resource.virglBacking {
            let box = vzvg_box(
                x: 0, y: 0, z: 0,
                w: UInt32(resource.width), h: UInt32(resource.height), d: 1
            )
            guard renderer.transfer(
                resourceID: resource.id, contextID: 0, level: 0,
                stride: UInt32(resource.width * 4), layerStride: 0,
                box: box, offset: 0, backing: backing.iovecs,
                count: backing.entries.count, toHost: false
            ) else {
                return VirtioGPU.responseHeader(.errorUnspecified, request: header)
            }
        }
        guard ensurePixelStorage(for: &resource) else {
            return VirtioGPU.responseHeader(.errorOutOfMemory, request: header)
        }
        copyBackingToPixels(&resource)
        resources[resource.id] = resource
        guard let image = makeImage(resource, preservesAlpha: true) else {
            return VirtioGPU.responseHeader(.errorUnspecified, request: header)
        }
        cursorResourceID = resource.id
        cursorUpdateCount += 1
        if cursorUpdateCount <= 5 || cursorUpdateCount.isMultiple(of: 500) {
            print(
                "[stage5] cursor update \(cursorUpdateCount): resource=\(resource.id), "
                    + "\(resource.width)x\(resource.height), position="
                    + "\(update.position.x),\(update.position.y), hotspot=\(update.hotX),\(update.hotY)"
            )
        }
        publishCursor(image: image, hotX: update.hotX, hotY: update.hotY)
        return VirtioGPU.responseHeader(.okNoData, request: header)
    }

    private func moveCursor(_ request: Data, header: VirtioGPU.Header) -> Data {
        guard request.count >= 56, let position = VirtioGPU.CursorPosition(request) else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        guard position.scanoutID == 0 else {
            return VirtioGPU.responseHeader(.errorInvalidScanoutID, request: header)
        }
        cursorPosition = position
        let isVisible = cursorResourceID != nil
        cursorMoveCount += 1
        if cursorMoveCount <= 5 || cursorMoveCount.isMultiple(of: 1_000) {
            print(
                "[stage5] cursor move \(cursorMoveCount): "
                    + "position=\(position.x),\(position.y), visible=\(isVisible)"
            )
        }
        Task { @MainActor [onCursor] in
            onCursor(.init(
                image: nil, x: position.x, y: position.y, hotX: 0, hotY: 0,
                replacesImage: false, isVisible: isVisible
            ))
        }
        return VirtioGPU.responseHeader(.okNoData, request: header)
    }

    private func publishCursor(image: CGImage?, hotX: UInt32, hotY: UInt32) {
        let position = cursorPosition
        Task { @MainActor [onCursor] in
            onCursor(.init(
                image: image, x: position.x, y: position.y, hotX: hotX, hotY: hotY,
                replacesImage: true, isVisible: image != nil
            ))
        }
    }

    private func transferToHost(_ request: Data, header: VirtioGPU.Header) -> Data {
        guard request.count >= 56 else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        let resourceID = request.littleEndianUInt32(at: 48)
        guard var resource = resources[resourceID], !resource.backing.isEmpty else {
            return VirtioGPU.responseHeader(.errorInvalidResourceID, request: header)
        }

        if resource.isRendererResource, let backing = resource.virglBacking {
            let rect = VirtioGPU.Rect(request, at: 24)
            guard VirtioGPU.rectIsContained(
                rect, resourceWidth: resource.width, resourceHeight: resource.height
            ) else {
                return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
            }
            let box = vzvg_box(x: rect.x, y: rect.y, z: 0, w: rect.width, h: rect.height, d: 1)
            guard renderer.transfer(
                resourceID: resourceID, contextID: 0, level: 0,
                stride: UInt32(resource.width * 4), layerStride: 0,
                box: box, offset: request.littleEndianUInt64(at: 40),
                backing: backing.iovecs, count: backing.entries.count, toHost: true
            ) else {
                return VirtioGPU.responseHeader(.errorUnspecified, request: header)
            }
        }

        guard ensurePixelStorage(for: &resource) else {
            return VirtioGPU.responseHeader(.errorOutOfMemory, request: header)
        }
        copyBackingToPixels(&resource)
        resources[resourceID] = resource
        return VirtioGPU.responseHeader(.okNoData, request: header)
    }

    private func flush(_ request: Data, header: VirtioGPU.Header) -> Data {
        guard request.count >= 48 else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        let resourceID = request.littleEndianUInt32(at: 40)
        resourceFlushCount &+= 1
        diagnosticWindowFlushCount &+= 1
        recordDiagnosticsIfNeeded(trigger: "flush")
        guard scanoutResourceID == resourceID, let scanoutRect,
              var resource = resources[resourceID] else {
            return VirtioGPU.responseHeader(.okNoData, request: header)
        }
        guard VirtioGPU.rectIsContained(
            VirtioGPU.Rect(request, at: 24),
            resourceWidth: resource.width,
            resourceHeight: resource.height
        ) else {
            return VirtioGPU.responseHeader(.errorInvalidParameter, request: header)
        }
        if !borrowedScanoutResources.contains(resourceID) {
            guard let texture = renderer.borrowScanoutTexture(resourceID: resourceID) else {
                // A flush may arrive before virglrenderer has materialized the
                // scanout texture. Do not poison the presentation loop with an
                // invalid resource; the next guest flush retries the borrow.
                return VirtioGPU.responseHeader(.okNoData, request: header)
            }
            borrowedScanoutResources.insert(resourceID)
            print(
                "[stage4] borrowed zero-copy scanout texture: resource=\(resourceID), "
                    + "texture=\(texture.id), \(texture.width)x\(texture.height), "
                    + "format=\(texture.format), stride=\(texture.stride)"
            )
        }
        if zeroCopyPresentationEnabled {
            lastPublishedScanoutResourceID = resourceID
            frameScheduler.submit(ScanoutFrame(
                resourceID: resourceID,
                x: Int(scanoutRect.x), y: Int(scanoutRect.y),
                width: Int(scanoutRect.width), height: Int(scanoutRect.height)
            ))
            let submitted = frameScheduler.submittedCount
            if submitted == 1 || submitted.isMultiple(of: 600) {
                diagnosticLog(
                    "presentation scheduler submitted=\(submitted) "
                        + "delivered=\(frameScheduler.deliveredCount) "
                        + "coalesced=\(frameScheduler.coalescedCount)"
                )
            }
            return VirtioGPU.responseHeader(.okNoData, request: header)
        }
        if resource.isRendererResource, let backing = resource.virglBacking {
            guard ensurePixelStorage(for: &resource) else {
                return VirtioGPU.responseHeader(.errorOutOfMemory, request: header)
            }
            let box = vzvg_box(
                x: 0, y: 0, z: 0,
                w: UInt32(resource.width), h: UInt32(resource.height), d: 1
            )
            _ = renderer.transfer(
                resourceID: resourceID, contextID: 0, level: 0,
                stride: UInt32(resource.width * 4), layerStride: 0,
                box: box, offset: 0, backing: backing.iovecs,
                count: backing.entries.count, toHost: false
            )
            copyBackingToPixels(&resource)
            resources[resourceID] = resource
        }
        publish(resource)
        return VirtioGPU.responseHeader(.okNoData, request: header)
    }

    private func copyBackingToPixels(_ resource: inout Resource) {
        var destinationOffset = 0
        resource.pixels.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for entry in resource.backing where destinationOffset < destination.count {
                let copyCount = min(entry.length, destination.count - destinationOffset)
                memcpy(
                    destinationBase.advanced(by: destinationOffset),
                    entry.mapping.mutableBytes,
                    copyCount
                )
                destinationOffset += copyCount
            }
        }
    }

    private func ensurePixelStorage(for resource: inout Resource) -> Bool {
        if !resource.pixels.isEmpty { return true }
        guard let byteCount = VirtioGPU.pixelByteCount(
            width: UInt32(resource.width), height: UInt32(resource.height)
        ), totalPixelBytes <= VirtioGPU.Limits.maxTotalPixelBytes - byteCount else { return false }
        resource.pixels = Data(count: byteCount)
        totalPixelBytes += byteCount
        return true
    }

    private func publish(_ resource: Resource) {
        publishedFrameCount += 1
        let sampledNonzeroBytes = resource.pixels.enumerated().lazy
            .filter { $0.offset.isMultiple(of: 4096) && $0.element != 0 }
            .prefix(16)
            .count
        if publishedFrameCount == 1 || publishedFrameCount.isMultiple(of: 300) {
            print(
                "[stage2] frame \(publishedFrameCount) flushed: "
                    + "\(resource.width)x\(resource.height), "
                    + "sampledNonzeroBytes=\(sampledNonzeroBytes)"
            )
        }
        guard let image = makeImage(resource) else { return }
        if !savedEvidenceFrame, sampledNonzeroBytes > 0 {
            let evidenceURL = URL(fileURLWithPath: "/tmp/ezvm-vz-gpu-scanout.png")
            if let destination = CGImageDestinationCreateWithURL(
                evidenceURL as CFURL,
                "public.png" as CFString,
                1,
                nil
            ) {
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) {
                    savedEvidenceFrame = true
                    print("[stage2] saved nonzero scanout evidence: \(evidenceURL.path)")
                }
            }
        }
        Task { @MainActor in
            onFrame(image)
        }
    }

    private func makeImage(_ resource: Resource, preservesAlpha: Bool = false) -> CGImage? {
        guard let provider = CGDataProvider(data: resource.pixels as CFData) else { return nil }
        // Virtio cursor resources are B8G8R8A8 with straight alpha. Combined
        // with byteOrder32Little, alphaFirst describes that in-memory layout.
        let alphaInfo: CGImageAlphaInfo = preservesAlpha ? .first : .noneSkipFirst
        return CGImage(
                width: resource.width,
                height: resource.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: resource.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue)
                    .union(.byteOrder32Little),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
    }

    private func write(_ response: Data, to element: VZVirtioQueueElement) {
        do {
            try element.write(response)
        } catch {
            print("[gpu] response write failed: \(error)")
        }
    }
}
