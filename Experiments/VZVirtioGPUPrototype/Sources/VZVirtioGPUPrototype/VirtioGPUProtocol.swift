import Foundation

enum VirtioGPU {
    static let deviceID: UInt16 = 16
    static let pciDisplayClass: UInt8 = 0x03
    static let pciOtherDisplaySubclass: UInt8 = 0x80
    static let queueCount: UInt16 = 2

    static let eventDisplay: UInt32 = 1 << 0
    static let flagFence: UInt32 = 1 << 0

    enum Limits {
        static let maxRequestBytes = 16 * 1024 * 1024
        static let maxSubmitBytes = 8 * 1024 * 1024
        static let maxDimension: UInt32 = 8_192
        static let maxResourceDepth: UInt32 = 2_048
        static let maxArraySize: UInt32 = 2_048
        static let maxMipLevel: UInt32 = 15
        static let maxSampleCount: UInt32 = 16
        static let maxResourceTexels: UInt64 = 256 * 1024 * 1024
        static let maxBufferBytes: UInt32 = 256 * 1024 * 1024
        static let maxRendererResourceBytes: UInt64 = 2 * 1024 * 1024 * 1024
        static let maxResources = 4_096
        static let maxContexts = 256
        static let maxResourcePixelBytes = 256 * 1024 * 1024
        static let maxTotalPixelBytes = 512 * 1024 * 1024
        static let maxBackingEntries = 4_096
        static let maxBackingBytes = 1024 * 1024 * 1024
        static let maxTotalBackingBytes: UInt64 = 4 * 1024 * 1024 * 1024
        // The virtio-gpu ABI standardizes a 64x64 cursor. Leave headroom for
        // guests that use larger HiDPI cursor planes without allowing a
        // general scanout-sized resource to become an AppKit cursor image.
        static let maxCursorDimension: UInt32 = 256
    }

    struct RendererResourceBudget: Equatable {
        let limit: UInt64
        private(set) var allocatedBytes: UInt64 = 0

        init(limit: UInt64 = Limits.maxRendererResourceBytes) {
            self.limit = limit
        }

        mutating func reserve(_ bytes: UInt64) -> Bool {
            guard bytes > 0, bytes <= limit,
                  allocatedBytes <= limit - bytes else { return false }
            allocatedBytes += bytes
            return true
        }

        mutating func release(_ bytes: UInt64) {
            allocatedBytes = bytes <= allocatedBytes ? allocatedBytes - bytes : 0
        }

        mutating func reset() {
            allocatedBytes = 0
        }
    }

    static func clampedDisplaySize(width: UInt32, height: UInt32) -> (width: UInt32, height: UInt32) {
        (
            max(640, min(Limits.maxDimension, width)),
            max(480, min(Limits.maxDimension, height))
        )
    }

    static func presentationRegion(
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> (x: UInt32, y: UInt32, width: UInt32, height: UInt32)? {
        guard let x = UInt32(exactly: x),
              let y = UInt32(exactly: y),
              let width = UInt32(exactly: width),
              let height = UInt32(exactly: height),
              width > 0, height > 0,
              UInt64(x) + UInt64(width) <= UInt64(UInt32.max),
              UInt64(y) + UInt64(height) <= UInt64(UInt32.max) else { return nil }
        return (x, y, width, height)
    }

    static func deviceConfigurationData(displayEvent: Bool) -> Data {
        // struct virtio_gpu_config: events_read, events_clear, num_scanouts,
        // num_capsets. VIRTIO_GPU_EVENT_DISPLAY is bit 0.
        var data = Data()
        data.appendLittleEndian(displayEvent ? eventDisplay : 0)
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(UInt32(1))
        data.appendLittleEndian(UInt32(1))
        return data
    }

    enum Queue: UInt16 {
        case control = 0
        case cursor = 1
    }

    enum Command: UInt32 {
        case getDisplayInfo = 0x0100
        case resourceCreate2D = 0x0101
        case resourceUnref = 0x0102
        case setScanout = 0x0103
        case resourceFlush = 0x0104
        case transferToHost2D = 0x0105
        case resourceAttachBacking = 0x0106
        case resourceDetachBacking = 0x0107
        case getCapsetInfo = 0x0108
        case getCapset = 0x0109
        case getEDID = 0x010a
        case contextCreate = 0x0200
        case contextDestroy = 0x0201
        case contextAttachResource = 0x0202
        case contextDetachResource = 0x0203
        case resourceCreate3D = 0x0204
        case transferToHost3D = 0x0205
        case transferFromHost3D = 0x0206
        case submit3D = 0x0207
        case updateCursor = 0x0300
        case moveCursor = 0x0301
    }

    enum Response: UInt32 {
        case okNoData = 0x1100
        case okDisplayInfo = 0x1101
        case okCapsetInfo = 0x1102
        case okCapset = 0x1103
        case okEDID = 0x1104
        case errorUnspecified = 0x1200
        case errorOutOfMemory = 0x1201
        case errorInvalidScanoutID = 0x1202
        case errorInvalidResourceID = 0x1203
        case errorInvalidParameter = 0x1205
    }

    static func command(_ command: Command, isValidOn queueIndex: UInt16) -> Bool {
        switch Queue(rawValue: queueIndex) {
        case .control:
            return command != .updateCursor && command != .moveCursor
        case .cursor:
            return command == .updateCursor || command == .moveCursor
        case nil:
            return false
        }
    }

    /// Fixed portion of each virtio-gpu request. Variable-length payloads are
    /// validated by their command handlers after this common boundary check.
    static func minimumRequestBytes(for command: Command) -> Int {
        switch command {
        case .getDisplayInfo, .contextDestroy:
            return 24
        case .resourceUnref, .resourceAttachBacking, .resourceDetachBacking,
             .getCapsetInfo, .getCapset, .getEDID, .contextAttachResource,
             .contextDetachResource, .submit3D:
            return 32
        case .resourceCreate2D:
            return 40
        case .setScanout, .resourceFlush:
            return 48
        case .transferToHost2D, .updateCursor:
            return 56
        case .resourceCreate3D, .transferToHost3D, .transferFromHost3D:
            return 72
        case .contextCreate:
            return 96
        case .moveCursor:
            // MOVE_CURSOR contains only the 24-byte header and 16-byte
            // virtio_gpu_cursor_pos; unlike UPDATE_CURSOR it has no resource.
            return 40
        }
    }

    static func pixelByteCount(width: UInt32, height: UInt32) -> Int? {
        guard width > 0, height > 0,
              width <= Limits.maxDimension, height <= Limits.maxDimension else { return nil }
        let pixels = UInt64(width) * UInt64(height)
        let bytes = pixels * 4
        guard bytes <= UInt64(Limits.maxResourcePixelBytes), bytes <= UInt64(Int.max) else { return nil }
        return Int(bytes)
    }

    static func cursorResourceIsSupported(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        return width <= Int(Limits.maxCursorDimension)
            && height <= Int(Limits.maxCursorDimension)
    }

    static func transferRegionIsValid(
        resourceWidth: UInt32,
        resourceHeight: UInt32,
        resourceLastLevel: UInt32,
        level: UInt32,
        x: UInt32,
        y: UInt32,
        z: UInt32,
        width: UInt32,
        height: UInt32,
        depth: UInt32
    ) -> Bool {
        guard resourceWidth > 0, resourceHeight > 0,
              level <= resourceLastLevel,
              width > 0, height > 0, depth > 0 else { return false }

        // Resource creation already caps lastLevel at 15. Compute mip edges in
        // UInt64 so guest coordinates can never wrap before comparison.
        let mipWidth = max(UInt64(1), UInt64(resourceWidth) >> level)
        let mipHeight = max(UInt64(1), UInt64(resourceHeight) >> level)
        let right = UInt64(x) + UInt64(width)
        let bottom = UInt64(y) + UInt64(height)
        let back = UInt64(z) + UInt64(depth)
        return right <= mipWidth
            && bottom <= mipHeight
            && back <= UInt64(UInt32.max)
    }

    static func valid3DResourceDimensions(
        target: UInt32,
        width: UInt32,
        height: UInt32,
        depth: UInt32,
        arraySize: UInt32,
        lastLevel: UInt32,
        sampleCount: UInt32
    ) -> Bool {
        // Gallium's PIPE_BUFFER uses width0 as a byte count rather than a
        // texture dimension. Applying the 8192 texture-edge limit to buffers
        // rejects ordinary vertex/index buffers and leaves later VirGL draws
        // referring to a resource the host never created.
        if target == 0 {
            return width > 0 && width <= Limits.maxBufferBytes
                && height == 1 && depth == 1 && arraySize == 1
                && lastLevel == 0 && sampleCount == 0
        }
        guard width > 0, height > 0, depth > 0, arraySize > 0,
              width <= Limits.maxDimension, height <= Limits.maxDimension,
              depth <= Limits.maxResourceDepth, arraySize <= Limits.maxArraySize,
              lastLevel <= Limits.maxMipLevel,
              sampleCount <= Limits.maxSampleCount else { return false }
        let texels = UInt64(width) * UInt64(height) * UInt64(depth) * UInt64(arraySize)
        return texels <= Limits.maxResourceTexels
    }

    /// Conservative host-allocation estimate used before crossing into
    /// virglrenderer. Texture formats can occupy up to 16 bytes per texel;
    /// mip chains are bounded by twice the base allocation, and multisampling
    /// scales storage by the declared sample count. PIPE_BUFFER width is
    /// already a byte count.
    static func estimatedRendererResourceBytes(
        target: UInt32,
        width: UInt32,
        height: UInt32,
        depth: UInt32,
        arraySize: UInt32,
        lastLevel: UInt32,
        sampleCount: UInt32
    ) -> UInt64? {
        guard valid3DResourceDimensions(
            target: target,
            width: width,
            height: height,
            depth: depth,
            arraySize: arraySize,
            lastLevel: lastLevel,
            sampleCount: sampleCount
        ) else { return nil }
        if target == 0 { return UInt64(width) }

        var estimate = UInt64(width)
        for factor in [UInt64(height), UInt64(depth), UInt64(arraySize), 16] {
            let result = estimate.multipliedReportingOverflow(by: factor)
            guard !result.overflow else { return nil }
            estimate = result.partialValue
        }
        let samples = max(UInt64(sampleCount), 1)
        let sampled = estimate.multipliedReportingOverflow(by: samples)
        guard !sampled.overflow else { return nil }
        estimate = sampled.partialValue
        if lastLevel > 0 {
            let mipmapped = estimate.multipliedReportingOverflow(by: 2)
            guard !mipmapped.overflow else { return nil }
            estimate = mipmapped.partialValue
        }
        return estimate
    }

    static func rectIsContained(
        _ rect: Rect,
        resourceWidth: Int,
        resourceHeight: Int
    ) -> Bool {
        guard rect.width > 0, rect.height > 0, resourceWidth > 0, resourceHeight > 0 else { return false }
        let right = UInt64(rect.x) + UInt64(rect.width)
        let bottom = UInt64(rect.y) + UInt64(rect.height)
        return right <= UInt64(resourceWidth) && bottom <= UInt64(resourceHeight)
    }

    struct Header {
        let type: UInt32
        let flags: UInt32
        let fenceID: UInt64
        let contextID: UInt32
        let padding: UInt32

        init?(_ data: Data) {
            guard data.count >= 24 else { return nil }
            type = data.littleEndianUInt32(at: 0)
            flags = data.littleEndianUInt32(at: 4)
            fenceID = data.littleEndianUInt64(at: 8)
            contextID = data.littleEndianUInt32(at: 16)
            padding = data.littleEndianUInt32(at: 20)
        }
    }

    struct Rect {
        let x: UInt32
        let y: UInt32
        let width: UInt32
        let height: UInt32

        init(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        init(_ data: Data, at offset: Int) {
            self.init(
                x: data.littleEndianUInt32(at: offset),
                y: data.littleEndianUInt32(at: offset + 4),
                width: data.littleEndianUInt32(at: offset + 8),
                height: data.littleEndianUInt32(at: offset + 12)
            )
        }
    }

    struct CursorPosition: Equatable {
        let scanoutID: UInt32
        let x: UInt32
        let y: UInt32

        init(scanoutID: UInt32, x: UInt32, y: UInt32) {
            self.scanoutID = scanoutID
            self.x = x
            self.y = y
        }

        init?(_ data: Data) {
            guard data.count >= 40 else { return nil }
            scanoutID = data.littleEndianUInt32(at: 24)
            x = data.littleEndianUInt32(at: 28)
            y = data.littleEndianUInt32(at: 32)
        }
    }

    struct CursorUpdate: Equatable {
        let position: CursorPosition
        let resourceID: UInt32
        let hotX: UInt32
        let hotY: UInt32

        init?(_ data: Data) {
            guard let position = CursorPosition(data), data.count >= 56 else { return nil }
            self.position = position
            resourceID = data.littleEndianUInt32(at: 40)
            hotX = data.littleEndianUInt32(at: 44)
            hotY = data.littleEndianUInt32(at: 48)
        }
    }

    static func responseHeader(_ response: Response, request: Header) -> Data {
        var data = Data()
        data.appendLittleEndian(response.rawValue)
        data.appendLittleEndian(request.flags)
        data.appendLittleEndian(request.fenceID)
        data.appendLittleEndian(request.contextID)
        data.appendLittleEndian(UInt32(0))
        return data
    }

    static func displayInfoResponse(request: Header, width: UInt32, height: UInt32) -> Data {
        var data = responseHeader(.okDisplayInfo, request: request)
        for index in 0..<16 {
            data.appendLittleEndian(UInt32(0))
            data.appendLittleEndian(UInt32(0))
            data.appendLittleEndian(index == 0 ? width : 0)
            data.appendLittleEndian(index == 0 ? height : 0)
            data.appendLittleEndian(index == 0 ? UInt32(1) : 0)
            data.appendLittleEndian(UInt32(0))
        }
        return data
    }

    static func edidResponse(request: Header, width: UInt32, height: UInt32) -> Data {
        let edid = makeEDID(width: width, height: height)
        var data = responseHeader(.okEDID, request: request)
        data.appendLittleEndian(UInt32(edid.count))
        data.appendLittleEndian(UInt32(0))
        data.append(edid)
        data.append(Data(repeating: 0, count: 1024 - edid.count))
        return data
    }

    static func makeEDID(width: UInt32, height: UInt32) -> Data {
        let size = clampedDisplaySize(width: width, height: height)
        let activeWidth = UInt16(min(size.width, 4095))
        let activeHeight = UInt16(min(size.height, 4095))
        let horizontalBlank = UInt16(max(160, (Int(activeWidth) / 5 + 7) & ~7))
        let verticalBlank = UInt16(max(45, Int(activeHeight) / 20))
        let totalWidth = UInt64(activeWidth) + UInt64(horizontalBlank)
        let totalHeight = UInt64(activeHeight) + UInt64(verticalBlank)
        let pixelClock = UInt16(min(UInt64(UInt16.max), (totalWidth * totalHeight * 60 + 5_000) / 10_000))

        var bytes = [UInt8](repeating: 0, count: 128)
        bytes[0..<8] = [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00]
        bytes[8] = 0x15 // "EZV"
        bytes[9] = 0x36
        bytes[10] = 0x01
        bytes[11] = 0x00
        bytes[16] = 1
        bytes[17] = 36 // 2026
        bytes[18] = 1
        bytes[19] = 4
        bytes[20] = 0xa5 // digital display
        bytes[21] = 52
        bytes[22] = 29
        bytes[23] = 120
        bytes[24] = 0x0a
        bytes[35] = 0x01
        bytes[36] = 0x01
        bytes[37] = 0x01
        bytes[38] = 0x01
        bytes[39] = 0x01
        bytes[40] = 0x01
        bytes[41] = 0x01
        bytes[42] = 0x01
        bytes[43] = 0x01
        bytes[44] = 0x01
        bytes[45] = 0x01
        bytes[46] = 0x01
        bytes[47] = 0x01
        bytes[48] = 0x01
        bytes[49] = 0x01
        bytes[50] = 0x01
        bytes[51] = 0x01
        bytes[52] = 0x01
        bytes[53] = 0x01

        let dtd = 54
        bytes[dtd] = UInt8(truncatingIfNeeded: pixelClock)
        bytes[dtd + 1] = UInt8(truncatingIfNeeded: pixelClock >> 8)
        bytes[dtd + 2] = UInt8(truncatingIfNeeded: activeWidth)
        bytes[dtd + 3] = UInt8(truncatingIfNeeded: horizontalBlank)
        bytes[dtd + 4] = UInt8((activeWidth >> 8) << 4) | UInt8(horizontalBlank >> 8)
        bytes[dtd + 5] = UInt8(truncatingIfNeeded: activeHeight)
        bytes[dtd + 6] = UInt8(truncatingIfNeeded: verticalBlank)
        bytes[dtd + 7] = UInt8((activeHeight >> 8) << 4) | UInt8(verticalBlank >> 8)
        let hSyncOffset = UInt16(max(8, Int(horizontalBlank) / 3))
        let hSyncWidth = UInt16(max(8, Int(horizontalBlank) / 6))
        let vSyncOffset: UInt16 = 3
        let vSyncWidth: UInt16 = 5
        bytes[dtd + 8] = UInt8(truncatingIfNeeded: hSyncOffset)
        bytes[dtd + 9] = UInt8(truncatingIfNeeded: hSyncWidth)
        bytes[dtd + 10] = UInt8((vSyncOffset & 0x0f) << 4 | (vSyncWidth & 0x0f))
        bytes[dtd + 11] = UInt8((hSyncOffset >> 8) << 6 | (hSyncWidth >> 8) << 4)
        bytes[dtd + 12] = 0x2c
        bytes[dtd + 13] = 0x1a
        bytes[dtd + 14] = 0x30
        bytes[dtd + 17] = 0x1a

        let name = Array("EZVM Display\n".utf8)
        bytes[72..<90] = [0, 0, 0, 0xfc, 0] + name
        bytes[126] = 0
        bytes[127] = UInt8(truncatingIfNeeded: 256 - bytes.prefix(127).reduce(0) { ($0 + Int($1)) & 0xff })
        return Data(bytes)
    }
}

extension Data {
    func littleEndianUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return withUnsafeBytes { raw in
            let byte0 = UInt32(raw[offset])
            let byte1 = UInt32(raw[offset + 1]) << 8
            let byte2 = UInt32(raw[offset + 2]) << 16
            let byte3 = UInt32(raw[offset + 3]) << 24
            return byte0 | byte1 | byte2 | byte3
        }
    }

    func littleEndianUInt64(at offset: Int) -> UInt64 {
        UInt64(littleEndianUInt32(at: offset))
            | UInt64(littleEndianUInt32(at: offset + 4)) << 32
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func appendLittleEndian(_ value: UInt64) {
        appendLittleEndian(UInt32(truncatingIfNeeded: value))
        appendLittleEndian(UInt32(truncatingIfNeeded: value >> 32))
    }
}
