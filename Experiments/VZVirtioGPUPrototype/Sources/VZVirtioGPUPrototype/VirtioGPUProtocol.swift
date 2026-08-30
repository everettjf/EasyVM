import Foundation

enum VirtioGPU {
    static let deviceID: UInt16 = 16
    static let pciDisplayClass: UInt8 = 0x03
    static let pciOtherDisplaySubclass: UInt8 = 0x80
    static let queueCount: UInt16 = 2

    static let eventDisplay: UInt32 = 1 << 0

    enum Limits {
        static let maxRequestBytes = 16 * 1024 * 1024
        static let maxSubmitBytes = 8 * 1024 * 1024
        static let maxDimension: UInt32 = 8_192
        static let maxResources = 4_096
        static let maxResourcePixelBytes = 256 * 1024 * 1024
        static let maxTotalPixelBytes = 512 * 1024 * 1024
        static let maxBackingEntries = 4_096
        static let maxBackingBytes = 1024 * 1024 * 1024
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

    static func pixelByteCount(width: UInt32, height: UInt32) -> Int? {
        guard width > 0, height > 0,
              width <= Limits.maxDimension, height <= Limits.maxDimension else { return nil }
        let pixels = UInt64(width) * UInt64(height)
        let bytes = pixels * 4
        guard bytes <= UInt64(Limits.maxResourcePixelBytes), bytes <= UInt64(Int.max) else { return nil }
        return Int(bytes)
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
