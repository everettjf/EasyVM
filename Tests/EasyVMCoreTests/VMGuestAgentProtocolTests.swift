import XCTest
@testable import EasyVMCore

final class VMGuestAgentProtocolTests: XCTestCase {
    private let token = Data(repeating: 0x5a, count: 32)
    private let machineID = "machine-a"
    private let guestNonce = Data(repeating: 0x11, count: 32).base64EncodedString()
    private let hostNonce = Data(repeating: 0x22, count: 32).base64EncodedString()

    func testMutualAuthenticationRoundTrip() throws {
        let guest = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let host = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let hello = try guest.makeHello(guestNonce: guestNonce)
        try host.verifyHello(hello)
        let welcome = try host.makeWelcome(guestNonce: guestNonce, hostNonce: hostNonce)
        try guest.verifyWelcome(welcome, guestNonce: guestNonce)
    }

    func testWrongTokenAndMachineCannotAuthenticate() throws {
        let guest = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let hello = try guest.makeHello(guestNonce: guestNonce)
        let wrongToken = try VMGuestAgentAuthenticator(tokenData: Data(repeating: 7, count: 32), machineID: machineID)
        XCTAssertThrowsError(try wrongToken.verifyHello(hello)) { XCTAssertEqual($0 as? VMGuestAgentAuthenticationError, .invalidProof) }
        let wrongMachine = try VMGuestAgentAuthenticator(tokenData: token, machineID: "machine-b")
        XCTAssertThrowsError(try wrongMachine.verifyHello(hello)) { XCTAssertEqual($0 as? VMGuestAgentAuthenticationError, .invalidMachine) }
    }

    func testInvalidVersionAndNonceAreRejected() throws {
        let authenticator = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let valid = try authenticator.makeHello(guestNonce: guestNonce)
        let future = VMGuestAgentHello(version: 99, machineID: valid.machineID, guestNonce: valid.guestNonce, proof: valid.proof)
        XCTAssertThrowsError(try authenticator.verifyHello(future))
        XCTAssertThrowsError(try authenticator.makeHello(guestNonce: Data("short".utf8).base64EncodedString()))
        XCTAssertThrowsError(try VMGuestAgentAuthenticator(tokenData: Data(), machineID: machineID))
    }

    func testEnvelopeIntegrityAndReplayProtection() throws {
        let sender = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        var receiver = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let sessionID = try sender.sessionID(guestNonce: guestNonce, hostNonce: hostNonce)
        let payload = try JSONEncoder().encode(VMGuestAgentStatus(
            agentVersion: "1.0", operatingSystem: "Alpine Linux", kernelVersion: "6.12",
            hostName: "easyvm", addresses: ["192.168.64.2"], bootID: "boot-a", uptimeSeconds: 12
        ))
        let envelope = try sender.makeEnvelope(sessionID: sessionID, sequence: 1, requestID: "request-1", operation: .status, payload: payload)
        try receiver.verifyEnvelope(envelope, sessionID: sessionID)
        XCTAssertThrowsError(try receiver.verifyEnvelope(envelope, sessionID: sessionID)) { XCTAssertEqual($0 as? VMGuestAgentAuthenticationError, .replayedSequence) }

        var fresh = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let changed = VMGuestAgentEnvelope(
            version: envelope.version, sessionID: envelope.sessionID, sequence: envelope.sequence, requestID: envelope.requestID,
            operation: .shutdown, payload: envelope.payload, proof: envelope.proof
        )
        XCTAssertThrowsError(try fresh.verifyEnvelope(changed, sessionID: sessionID)) { XCTAssertEqual($0 as? VMGuestAgentAuthenticationError, .invalidProof) }

        var reconnected = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let nextSession = try sender.sessionID(
            guestNonce: Data(repeating: 0x33, count: 32).base64EncodedString(), hostNonce: hostNonce
        )
        XCTAssertThrowsError(try reconnected.verifyEnvelope(envelope, sessionID: nextSession)) {
            XCTAssertEqual($0 as? VMGuestAgentAuthenticationError, .invalidProof)
        }
    }

    func testLengthPrefixedFrameRoundTripAndLimits() throws {
        let hello = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID).makeHello(guestNonce: guestNonce)
        let frame = try VMGuestAgentFrameCodec.encode(hello)
        XCTAssertEqual(try VMGuestAgentFrameCodec.decode(VMGuestAgentHello.self, from: frame), hello)
        XCTAssertThrowsError(try VMGuestAgentFrameCodec.decode(VMGuestAgentHello.self, from: frame.dropLast()))

        let oversized = Data(repeating: 0, count: VMGuestAgentProtocol.maximumFrameBytes + 1)
        XCTAssertThrowsError(try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
            .makeEnvelope(sessionID: "session", sequence: 1, requestID: "large", operation: .status, payload: oversized))
    }

    func testStatusPayloadRoundTrips() throws {
        let status = VMGuestAgentStatus(
            agentVersion: "1.2.3", operatingSystem: "Ubuntu 26.04", kernelVersion: "7.0",
            hostName: "builder", addresses: ["10.0.2.15", "fd00::15"], bootID: "abc", uptimeSeconds: 99
        )
        XCTAssertEqual(try JSONDecoder().decode(VMGuestAgentStatus.self, from: JSONEncoder().encode(status)), status)
        XCTAssertEqual(Set(VMGuestAgentOperation.allCases), [.heartbeat, .status, .shutdown, .restart])
    }

    func testFrameBufferHandlesPartialAndCoalescedReads() throws {
        let auth = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        let first = try VMGuestAgentFrameCodec.encode(auth.makeHello(guestNonce: guestNonce))
        let second = try VMGuestAgentFrameCodec.encode(auth.makeWelcome(guestNonce: guestNonce, hostNonce: hostNonce))
        var buffer = VMGuestAgentFrameBuffer()
        XCTAssertTrue(try buffer.append(first.prefix(3)).isEmpty)
        XCTAssertEqual(try buffer.append(first.dropFirst(3) + second).count, 2)
        XCTAssertTrue(buffer.data.isEmpty)
    }

    func testFrameBufferRejectsAdvertisedOversizedFrameBeforePayloadArrives() throws {
        var length = UInt32(VMGuestAgentProtocol.maximumFrameBytes + 1).bigEndian
        let header = Data(bytes: &length, count: 4)
        var buffer = VMGuestAgentFrameBuffer()
        XCTAssertThrowsError(try buffer.append(header)) {
            XCTAssertEqual($0 as? VMGuestAgentAuthenticationError, .oversizedFrame)
        }
    }

    func testProtocolMatchesPublishedCrossLanguageVectors() throws {
        let authenticator = try VMGuestAgentAuthenticator(tokenData: token, machineID: machineID)
        XCTAssertEqual(
            try authenticator.makeHello(guestNonce: guestNonce).proof,
            "Q2bgyj5cc0VI41gARg64PlS3qA7/poair6kJ5ISyz30="
        )
        XCTAssertEqual(
            try authenticator.makeWelcome(guestNonce: guestNonce, hostNonce: hostNonce).proof,
            "TK3n9Y+ST9leXS55GQaolfhS9ElcRZDY2OHuPvqXndo="
        )
        XCTAssertEqual(
            try authenticator.makeEnvelope(
                sessionID: "session-a", sequence: 7, requestID: "request-7",
                operation: .status, payload: Data("payload".utf8)
            ).proof,
            "OtNjPmizYoCykrwAy2LUpE2yLnzThrxYkdHq77yVfi4="
        )
    }

    func testLivenessExpiresOnlyAfterResponseTimeoutAndResets() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var liveness = VMGuestAgentLiveness()
        XCTAssertFalse(liveness.hasExpired(at: start.addingTimeInterval(100)))
        liveness.markResponse(at: start)
        XCTAssertFalse(liveness.hasExpired(at: start.addingTimeInterval(30)))
        XCTAssertTrue(liveness.hasExpired(at: start.addingTimeInterval(30.001)))
        liveness.reset()
        XCTAssertFalse(liveness.hasExpired(at: start.addingTimeInterval(100)))
    }
}
