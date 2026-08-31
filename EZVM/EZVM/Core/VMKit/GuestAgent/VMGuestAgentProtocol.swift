import AppKit
import CryptoKit
import Darwin
import Foundation

enum VMDisplayGeometry {
    static func guestResolution(for size: CGSize) -> (width: UInt32, height: UInt32) {
        func dimension(_ value: CGFloat, minimum: Int) -> UInt32 {
            let bounded = max(CGFloat(minimum), min(8192, value.rounded()))
            // Stable even dimensions avoid a new DRM mode for one-point layout
            // jitter while remaining valid for common compositor buffers.
            return UInt32(Int(bounded) & ~1)
        }
        return (dimension(size.width, minimum: 640), dimension(size.height, minimum: 480))
    }

    static func aspectFit(content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

struct VMScrollWheelAccumulator {
    private var preciseRemainder: CGFloat = 0
    private static let precisePointsPerDetent: CGFloat = 3

    mutating func consume(delta: CGFloat, hasPreciseDeltas: Bool) -> Int32 {
        guard delta.isFinite else { return 0 }
        if !hasPreciseDeltas {
            return Int32(max(-32767, min(32767, Int(delta.rounded()))))
        }

        // AppKit reports trackpad scrolling in fractional pixels while Linux
        // REL_WHEEL expects integral detents. Preserve sub-detent motion across
        // events so a slow two-finger gesture is not rounded away completely.
        preciseRemainder += delta
        let detents = Int(preciseRemainder / Self.precisePointsPerDetent)
        preciseRemainder -= CGFloat(detents) * Self.precisePointsPerDetent
        return Int32(max(-32767, min(32767, detents)))
    }
}

enum VMGuestAgentProtocol {
    static let version = 1
    static let port: UInt32 = 10240
    static let maximumFrameBytes = 1024 * 1024
    static let fileChunkBytes = 512 * 1024
    static let maximumTransferBytes: UInt64 = 64 * 1024 * 1024 * 1024
}

struct VMGuestAgentHello: Codable, Equatable {
    let version: Int
    let machineID: String
    let guestNonce: String
    let proof: String
}

struct VMGuestAgentWelcome: Codable, Equatable {
    let version: Int
    let hostNonce: String
    let proof: String
}

enum VMGuestAgentOperation: String, Codable, CaseIterable {
    case heartbeat
    case status
    case shutdown
    case restart
    case uploadStart
    case uploadChunk
    case uploadCommit
    case transferCancel
    case downloadInfo
    case downloadChunk
    case input
}

struct VMGuestAgentInputEvent: Codable, Equatable {
    let type: UInt16
    let code: UInt16
    let value: Int32
}

struct VMGuestAgentInputBatch: Codable, Equatable {
    static let maximumEventCount = 64
    let events: [VMGuestAgentInputEvent]

    static func key(code: UInt16, pressed: Bool) -> Self {
        VMGuestAgentInputBatch(events: [
            VMGuestAgentInputEvent(type: 1, code: code, value: pressed ? 1 : 0),
            VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
        ])
    }
}

struct VMGuestAgentInputResult: Codable, Equatable {
    let success: Bool
    let message: String
}

enum VMGuestAgentKeyboard {
    private static let macToLinux: [UInt16: UInt16] = [
        0: 30, 1: 31, 2: 32, 3: 33, 4: 35, 5: 34, 6: 44, 7: 45,
        8: 46, 9: 47, 11: 48, 12: 16, 13: 17, 14: 18, 15: 19,
        16: 21, 17: 20, 18: 2, 19: 3, 20: 4, 21: 5, 22: 7, 23: 6,
        24: 13, 25: 10, 26: 8, 27: 12, 28: 9, 29: 11, 30: 27,
        31: 24, 32: 22, 33: 26, 34: 23, 35: 25, 36: 28, 37: 38,
        38: 36, 39: 40, 40: 37, 41: 39, 42: 43, 43: 51, 44: 53,
        45: 49, 46: 50, 47: 52, 48: 15, 49: 57, 50: 41, 51: 14,
        53: 1, 54: 126, 55: 125, 56: 42, 57: 58, 58: 56, 59: 29,
        60: 54, 61: 100, 62: 97, 122: 59, 120: 60, 99: 61,
        118: 62, 96: 63, 97: 64, 98: 65, 100: 66, 101: 67,
        109: 68, 103: 87, 111: 88, 105: 183, 107: 184, 113: 185,
        106: 186, 64: 187, 79: 188, 80: 189, 90: 190,
        65: 83, 67: 55, 69: 78, 71: 69, 75: 98,
        76: 96, 78: 74, 81: 117, 82: 82, 83: 79, 84: 80,
        85: 81, 86: 75, 87: 76, 88: 77, 89: 71, 91: 72,
        92: 73, 117: 111, 115: 102, 116: 104, 119: 107,
        121: 109, 123: 105, 124: 106, 125: 108, 126: 103,
    ]

    private static let modifierFlags: [UInt16: NSEvent.ModifierFlags] = [
        54: .command, 55: .command,
        56: .shift, 60: .shift,
        57: .capsLock,
        58: .option, 61: .option,
        59: .control, 62: .control,
    ]

    static func linuxKeyCode(forMacVirtualKey keyCode: UInt16) -> UInt16? {
        macToLinux[keyCode]
    }

    static func modifierPressed(forMacVirtualKey keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool? {
        guard let modifier = modifierFlags[keyCode] else { return nil }
        return flags.intersection(.deviceIndependentFlagsMask).contains(modifier)
    }
}

struct VMGuestAgentUploadStart: Codable, Equatable {
    let transferID: String
    let destinationPath: String
    let totalBytes: UInt64
    let sha256: String
    let overwrite: Bool
}

struct VMGuestAgentUploadChunk: Codable, Equatable {
    let transferID: String
    let offset: UInt64
    let data: Data
}

struct VMGuestAgentTransferID: Codable, Equatable {
    let transferID: String
}

struct VMGuestAgentDownloadInfoRequest: Codable, Equatable {
    let transferID: String
    let sourcePath: String
}

struct VMGuestAgentDownloadChunkRequest: Codable, Equatable {
    let transferID: String
    let offset: UInt64
    let length: Int
}

struct VMGuestAgentDownloadInfo: Codable, Equatable {
    let transferID: String
    let totalBytes: UInt64
    let sha256: String
}

struct VMGuestAgentDownloadChunk: Codable, Equatable {
    let transferID: String
    let offset: UInt64
    let data: Data
    let eof: Bool
}

struct VMGuestAgentTransferResult: Codable, Equatable {
    let transferID: String
    let success: Bool
    let transferredBytes: UInt64
    let message: String
    let totalBytes: UInt64?
    let sha256: String?
    let offset: UInt64?
    let data: Data?
    let eof: Bool?
}

enum VMGuestAgentTransferValidationError: LocalizedError, Equatable {
    case invalidTransferID
    case invalidPath
    case invalidSize
    case invalidChecksum
    case invalidChunk

    var errorDescription: String? {
        switch self {
        case .invalidTransferID: "The transfer identifier is invalid."
        case .invalidPath: "The guest path must be absolute and must not contain a NUL byte."
        case .invalidSize: "The file exceeds EZVM's transfer size limit."
        case .invalidChecksum: "The SHA-256 checksum is invalid."
        case .invalidChunk: "The file-transfer chunk is invalid."
        }
    }
}

enum VMGuestAgentTransferValidator {
    static func validate(transferID: String) throws {
        guard UUID(uuidString: transferID) != nil else { throw VMGuestAgentTransferValidationError.invalidTransferID }
    }

    static func validate(path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw VMGuestAgentTransferValidationError.invalidPath }
    }

    static func validate(totalBytes: UInt64, sha256: String) throws {
        guard totalBytes <= VMGuestAgentProtocol.maximumTransferBytes else { throw VMGuestAgentTransferValidationError.invalidSize }
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }) else { throw VMGuestAgentTransferValidationError.invalidChecksum }
    }

    static func validate(offset: UInt64, data: Data) throws {
        guard data.count <= VMGuestAgentProtocol.fileChunkBytes,
              offset <= VMGuestAgentProtocol.maximumTransferBytes else {
            throw VMGuestAgentTransferValidationError.invalidChunk
        }
    }
}

enum VMGuestAgentSSH {
    static func url(username: String, address: String) -> URL? {
        guard isValidUsername(username), isValidAddress(address) else { return nil }
        let host = address.contains(":") ? "[\(address)]" : address
        return URL(string: "ssh://\(username)@\(host)")
    }

    static func isValidUsername(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 32, value.first?.isLetter == true else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    private static func isValidAddress(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains("%"), !value.contains("/") else { return false }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return value.withCString {
            inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1
        }
    }
}

struct VMGuestAgentEnvelope: Codable, Equatable {
    let version: Int
    let sessionID: String
    let sequence: UInt64
    let requestID: String
    let operation: VMGuestAgentOperation
    let payload: Data
    let proof: String
}

struct VMGuestAgentStatus: Codable, Equatable {
    let agentVersion: String
    let operatingSystem: String
    let kernelVersion: String
    let hostName: String
    let addresses: [String]
    let bootID: String
    let uptimeSeconds: UInt64
    let capabilities: [String]?
    let kvmAvailable: Bool?
    let kvmAPIVersion: Int?
    let kvmError: String?

    init(agentVersion: String, operatingSystem: String, kernelVersion: String, hostName: String,
         addresses: [String], bootID: String, uptimeSeconds: UInt64, capabilities: [String]?,
         kvmAvailable: Bool? = nil, kvmAPIVersion: Int? = nil, kvmError: String? = nil) {
        self.agentVersion = agentVersion
        self.operatingSystem = operatingSystem
        self.kernelVersion = kernelVersion
        self.hostName = hostName
        self.addresses = addresses
        self.bootID = bootID
        self.uptimeSeconds = uptimeSeconds
        self.capabilities = capabilities
        self.kvmAvailable = kvmAvailable
        self.kvmAPIVersion = kvmAPIVersion
        self.kvmError = kvmError
    }

    var supportsSSH: Bool { capabilities?.contains("ssh-addresses-v1") == true }
    var supportsFileTransfer: Bool { capabilities?.contains("file-transfer-v1") == true }
    var supportsGuestInput: Bool { capabilities?.contains("input-uinput-v1") == true }
    var supportsKVMDiagnostics: Bool { capabilities?.contains("kvm-diagnostics-v1") == true }
}

enum VMGuestAgentAuthenticationError: LocalizedError, Equatable {
    case invalidToken
    case incompatibleVersion(Int)
    case invalidMachine
    case invalidNonce
    case invalidProof
    case replayedSequence
    case oversizedFrame

    var errorDescription: String? {
        switch self {
        case .invalidToken: "The guest-agent token is invalid."
        case .incompatibleVersion(let value): "Guest-agent protocol version \(value) is unsupported."
        case .invalidMachine: "The guest agent belongs to a different virtual machine."
        case .invalidNonce: "The guest-agent nonce is invalid."
        case .invalidProof: "Guest-agent authentication failed."
        case .replayedSequence: "The guest-agent message was replayed or arrived out of order."
        case .oversizedFrame: "The guest-agent frame exceeds the size limit."
        }
    }
}

struct VMGuestAgentAuthenticator {
    private let token: SymmetricKey
    let machineID: String
    private(set) var lastReceivedSequence: UInt64 = 0

    init(tokenData: Data, machineID: String) throws {
        guard tokenData.count == 32 else { throw VMGuestAgentAuthenticationError.invalidToken }
        guard !machineID.isEmpty else { throw VMGuestAgentAuthenticationError.invalidMachine }
        token = SymmetricKey(data: tokenData)
        self.machineID = machineID
    }

    static func generateToken() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    func makeHello(guestNonce: String) throws -> VMGuestAgentHello {
        guard Self.validNonce(guestNonce) else { throw VMGuestAgentAuthenticationError.invalidNonce }
        return VMGuestAgentHello(
            version: VMGuestAgentProtocol.version,
            machineID: machineID,
            guestNonce: guestNonce,
            proof: sign("guest|\(VMGuestAgentProtocol.version)|\(machineID)|\(guestNonce)")
        )
    }

    func verifyHello(_ hello: VMGuestAgentHello) throws {
        guard hello.version == VMGuestAgentProtocol.version else {
            throw VMGuestAgentAuthenticationError.incompatibleVersion(hello.version)
        }
        guard hello.machineID == machineID else { throw VMGuestAgentAuthenticationError.invalidMachine }
        guard Self.validNonce(hello.guestNonce) else { throw VMGuestAgentAuthenticationError.invalidNonce }
        let expected = sign("guest|\(hello.version)|\(hello.machineID)|\(hello.guestNonce)")
        guard Self.constantTimeEqual(expected, hello.proof) else { throw VMGuestAgentAuthenticationError.invalidProof }
    }

    func makeWelcome(guestNonce: String, hostNonce: String) throws -> VMGuestAgentWelcome {
        guard Self.validNonce(guestNonce), Self.validNonce(hostNonce) else {
            throw VMGuestAgentAuthenticationError.invalidNonce
        }
        return VMGuestAgentWelcome(
            version: VMGuestAgentProtocol.version,
            hostNonce: hostNonce,
            proof: sign("host|\(VMGuestAgentProtocol.version)|\(machineID)|\(guestNonce)|\(hostNonce)")
        )
    }

    func verifyWelcome(_ welcome: VMGuestAgentWelcome, guestNonce: String) throws {
        guard welcome.version == VMGuestAgentProtocol.version else {
            throw VMGuestAgentAuthenticationError.incompatibleVersion(welcome.version)
        }
        guard Self.validNonce(guestNonce), Self.validNonce(welcome.hostNonce) else {
            throw VMGuestAgentAuthenticationError.invalidNonce
        }
        let expected = sign("host|\(welcome.version)|\(machineID)|\(guestNonce)|\(welcome.hostNonce)")
        guard Self.constantTimeEqual(expected, welcome.proof) else { throw VMGuestAgentAuthenticationError.invalidProof }
    }

    func sessionID(guestNonce: String, hostNonce: String) throws -> String {
        guard Self.validNonce(guestNonce), Self.validNonce(hostNonce) else {
            throw VMGuestAgentAuthenticationError.invalidNonce
        }
        return Data(SHA256.hash(data: Data("session|\(machineID)|\(guestNonce)|\(hostNonce)".utf8))).base64EncodedString()
    }

    func makeEnvelope(sessionID: String, sequence: UInt64, requestID: String, operation: VMGuestAgentOperation, payload: Data) throws -> VMGuestAgentEnvelope {
        guard !sessionID.isEmpty else { throw VMGuestAgentAuthenticationError.invalidNonce }
        guard payload.count <= VMGuestAgentProtocol.maximumFrameBytes else { throw VMGuestAgentAuthenticationError.oversizedFrame }
        let unsigned = Self.envelopeSigningText(
            version: VMGuestAgentProtocol.version, sessionID: sessionID, sequence: sequence,
            requestID: requestID, operation: operation, payload: payload
        )
        return VMGuestAgentEnvelope(
            version: VMGuestAgentProtocol.version, sessionID: sessionID, sequence: sequence, requestID: requestID,
            operation: operation, payload: payload, proof: sign(unsigned)
        )
    }

    mutating func verifyEnvelope(_ envelope: VMGuestAgentEnvelope, sessionID: String) throws {
        guard envelope.version == VMGuestAgentProtocol.version else {
            throw VMGuestAgentAuthenticationError.incompatibleVersion(envelope.version)
        }
        guard envelope.payload.count <= VMGuestAgentProtocol.maximumFrameBytes else {
            throw VMGuestAgentAuthenticationError.oversizedFrame
        }
        guard envelope.sessionID == sessionID else { throw VMGuestAgentAuthenticationError.invalidProof }
        guard envelope.sequence > lastReceivedSequence else { throw VMGuestAgentAuthenticationError.replayedSequence }
        let unsigned = Self.envelopeSigningText(
            version: envelope.version, sessionID: envelope.sessionID, sequence: envelope.sequence,
            requestID: envelope.requestID, operation: envelope.operation, payload: envelope.payload
        )
        guard Self.constantTimeEqual(sign(unsigned), envelope.proof) else {
            throw VMGuestAgentAuthenticationError.invalidProof
        }
        lastReceivedSequence = envelope.sequence
    }

    private func sign(_ value: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: token)).base64EncodedString()
    }

    private static func envelopeSigningText(
        version: Int, sessionID: String, sequence: UInt64, requestID: String,
        operation: VMGuestAgentOperation, payload: Data
    ) -> String {
        "message|\(version)|\(sessionID)|\(sequence)|\(requestID)|\(operation.rawValue)|\(payload.base64EncodedString())"
    }

    private static func validNonce(_ value: String) -> Bool {
        guard let data = Data(base64Encoded: value) else { return false }
        return data.count >= 24 && data.count <= 64
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = Data(base64Encoded: lhs), let right = Data(base64Encoded: rhs), left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

enum VMGuestAgentFrameCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        guard payload.count <= VMGuestAgentProtocol.maximumFrameBytes else {
            throw VMGuestAgentAuthenticationError.oversizedFrame
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        return frame
    }

    static func decode<T: Decodable>(_ type: T.Type, from frame: Data) throws -> T {
        guard frame.count >= 4 else { throw CocoaError(.fileReadCorruptFile) }
        let length = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= VMGuestAgentProtocol.maximumFrameBytes else { throw VMGuestAgentAuthenticationError.oversizedFrame }
        guard frame.count == Int(length) + 4 else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(type, from: frame.dropFirst(4))
    }
}

struct VMGuestAgentFrameBuffer {
    private(set) var data = Data()

    mutating func append(_ chunk: Data) throws -> [Data] {
        data.append(chunk)
        var frames: [Data] = []
        while data.count >= 4 {
            let length = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= VMGuestAgentProtocol.maximumFrameBytes else {
                throw VMGuestAgentAuthenticationError.oversizedFrame
            }
            let frameSize = Int(length) + 4
            guard data.count >= frameSize else { break }
            frames.append(data.prefix(frameSize))
            data.removeFirst(frameSize)
        }
        guard data.count <= VMGuestAgentProtocol.maximumFrameBytes + 4 else {
            throw VMGuestAgentAuthenticationError.oversizedFrame
        }
        return frames
    }
}

struct VMGuestAgentLiveness {
    static let timeout: TimeInterval = 30
    private(set) var lastResponseAt: Date?

    mutating func markResponse(at date: Date = Date()) {
        lastResponseAt = date
    }

    mutating func reset() {
        lastResponseAt = nil
    }

    func hasExpired(at date: Date = Date()) -> Bool {
        guard let lastResponseAt else { return false }
        return date.timeIntervalSince(lastResponseAt) > Self.timeout
    }
}

struct VMGuestAgentLocalFileMetadata: Equatable, Sendable {
    let size: UInt64
    let sha256: String
}

enum VMGuestAgentLocalFileError: LocalizedError {
    case notRegularFile
    case fileTooLarge
    case insufficientSpace
    case invalidChunk
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .notRegularFile: "The selected item is not a regular file."
        case .fileTooLarge: "The selected file exceeds EZVM's transfer size limit."
        case .insufficientSpace: "There is not enough free disk space for this transfer."
        case .invalidChunk: "The received file chunk is out of order or too large."
        case .checksumMismatch: "The transferred file failed SHA-256 verification."
        }
    }
}

enum VMGuestAgentLocalFile {
    static func metadata(at url: URL) throws -> VMGuestAgentLocalFileMetadata {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VMGuestAgentLocalFileError.notRegularFile
        }
        let size = UInt64(values.fileSize ?? 0)
        guard size <= VMGuestAgentProtocol.maximumTransferBytes else {
            throw VMGuestAgentLocalFileError.fileTooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: VMGuestAgentProtocol.fileChunkBytes), !data.isEmpty {
            hasher.update(data: data)
        }
        return VMGuestAgentLocalFileMetadata(
            size: size,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    static func readChunk(at url: URL, offset: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: VMGuestAgentProtocol.fileChunkBytes) ?? Data()
    }
}

final class VMGuestAgentDownloadTransaction {
    let destination: URL
    let totalBytes: UInt64
    let expectedSHA256: String
    private(set) var writtenBytes: UInt64 = 0
    private let staging: URL
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var finished = false

    init(destination: URL, totalBytes: UInt64, expectedSHA256: String) throws {
        try VMGuestAgentTransferValidator.validate(totalBytes: totalBytes, sha256: expectedSHA256)
        let parent = destination.deletingLastPathComponent()
        let capacity = try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        if let capacity, capacity >= 0, UInt64(capacity) < totalBytes {
            throw VMGuestAgentLocalFileError.insufficientSpace
        }
        self.destination = destination
        self.totalBytes = totalBytes
        self.expectedSHA256 = expectedSHA256.lowercased()
        staging = parent.appendingPathComponent(".ezvm-download-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: staging)
    }

    deinit {
        if !finished {
            try? handle?.close()
            try? FileManager.default.removeItem(at: staging)
        }
    }

    func append(offset: UInt64, data: Data) throws {
        guard !finished, offset == writtenBytes,
              data.count <= VMGuestAgentProtocol.fileChunkBytes,
              writtenBytes + UInt64(data.count) <= totalBytes else {
            throw VMGuestAgentLocalFileError.invalidChunk
        }
        try handle?.write(contentsOf: data)
        hasher.update(data: data)
        writtenBytes += UInt64(data.count)
    }

    func commit() throws {
        guard !finished, writtenBytes == totalBytes else { throw VMGuestAgentLocalFileError.invalidChunk }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256 else { throw VMGuestAgentLocalFileError.checksumMismatch }
        try handle?.synchronize()
        try handle?.close()
        handle = nil
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        finished = true
    }

    func cancel() {
        guard !finished else { return }
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: staging)
        finished = true
    }
}
