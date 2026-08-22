import CryptoKit
import Foundation

enum VMGuestAgentProtocol {
    static let version = 1
    static let port: UInt32 = 10240
    static let maximumFrameBytes = 1024 * 1024
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
