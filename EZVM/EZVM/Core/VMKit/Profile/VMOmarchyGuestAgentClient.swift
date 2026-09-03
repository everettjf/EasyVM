import Darwin
import Foundation
import Virtualization

public struct VMOmarchyGuestStatus: Equatable, Sendable {
    public let agentVersion: String
    public let hostName: String
    public let addresses: [String]
    public let capabilities: Set<String>
    public let desktopSessionActive: Bool
}

public enum VMOmarchyIntegrationState: Equatable, Sendable {
    case connecting
    case authenticating
    case ready(VMOmarchyGuestStatus)
    case disconnected(String)
}

@MainActor
public final class VMOmarchyGuestAgentClient {
    private let device: VZVirtioSocketDevice
    private let enrollment: VMGuestAgentEnrollment
    private let stateChanged: (VMOmarchyIntegrationState) -> Void
    private let ioQueue = DispatchQueue(label: "com.everettjf.ezvm.omarchy.agent", qos: .utility)
    private let writeLock = NSLock()
    private var connection: VZVirtioSocketConnection?
    private var generation: UInt64 = 0
    private var sessionID: String?
    private var sendSequence: UInt64 = 0
    private var retryTask: DispatchWorkItem?
    private var retryFailureCount = 0
    private var heartbeatTimer: Timer?
    private var lastResponseAt = Date.distantPast
    private var stopped = false

    public init(
        device: VZVirtioSocketDevice,
        layout: VMOmarchyWorkspaceLayout,
        stateChanged: @escaping (VMOmarchyIntegrationState) -> Void
    ) throws {
        self.device = device
        self.stateChanged = stateChanged
        let data = try Data(contentsOf: layout.enrollment.appending(path: "config.json"))
        let enrollment = try JSONDecoder().decode(VMGuestAgentEnrollment.self, from: data)
        try enrollment.validate()
        self.enrollment = enrollment
    }

    public func start() {
        guard !stopped else { return }
        connect()
    }

    public func stop() {
        stopped = true
        generation &+= 1
        retryTask?.cancel()
        retryTask = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        closeConnection()
        connection = nil
        sessionID = nil
    }

    public func requestShutdown() { send(.shutdown) }
    public func requestRestart() { send(.restart) }

    private func connect() {
        guard !stopped else { return }
        generation &+= 1
        let currentGeneration = generation
        stateChanged(.connecting)
        device.connect(toPort: VMGuestAgentProtocol.port) { [weak self] result in
            Task { @MainActor in
                guard let self, !self.stopped, self.generation == currentGeneration else { return }
                switch result {
                case .success(let connection): self.begin(connection, generation: currentGeneration)
                case .failure(let error): self.disconnected(error.localizedDescription, generation: currentGeneration)
                }
            }
        }
    }

    private func begin(_ connection: VZVirtioSocketConnection, generation: UInt64) {
        self.connection = connection
        stateChanged(.authenticating)
        let enrollment = enrollment
        let descriptor = connection.fileDescriptor
        ioQueue.async { [weak self] in
            self?.readLoop(
                descriptor: descriptor,
                enrollment: enrollment,
                generation: generation
            )
        }
    }

    private nonisolated func readLoop(
        descriptor: Int32,
        enrollment: VMGuestAgentEnrollment,
        generation: UInt64
    ) {
        var buffer = VMGuestAgentFrameBuffer()
        var authenticator: VMGuestAgentAuthenticator
        do {
            authenticator = try VMGuestAgentAuthenticator(
                tokenData: enrollment.token,
                machineID: enrollment.machineID
            )
        } catch {
            reportDisconnect(error.localizedDescription, generation: generation)
            return
        }
        var activeSessionID: String?
        do {
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { usleep(10_000); continue }
                if count < 0 && errno == EINTR { continue }
                if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if count == 0 { throw CocoaError(.fileReadUnknown) }
                for frame in try buffer.append(Data(bytes.prefix(count))) {
                    if activeSessionID == nil {
                        let hello = try VMGuestAgentFrameCodec.decode(VMGuestAgentHello.self, from: frame)
                        try authenticator.verifyHello(hello)
                        let hostNonce = VMGuestAgentAuthenticator.generateToken().base64EncodedString()
                        let welcome = try authenticator.makeWelcome(
                            guestNonce: hello.guestNonce,
                            hostNonce: hostNonce
                        )
                        let established = try authenticator.sessionID(
                            guestNonce: hello.guestNonce,
                            hostNonce: hostNonce
                        )
                        try Self.writeAll(
                            descriptor: descriptor,
                            data: VMGuestAgentFrameCodec.encode(welcome)
                        )
                        activeSessionID = established
                        Task { @MainActor [weak self] in
                            self?.authenticated(sessionID: established, generation: generation)
                        }
                    } else if let activeSessionID {
                        let envelope = try VMGuestAgentFrameCodec.decode(VMGuestAgentEnvelope.self, from: frame)
                        try authenticator.verifyEnvelope(envelope, sessionID: activeSessionID)
                        Task { @MainActor [weak self] in
                            self?.received(envelope, generation: generation)
                        }
                    }
                }
            }
        } catch {
            reportDisconnect(error.localizedDescription, generation: generation)
        }
    }

    private nonisolated func reportDisconnect(_ reason: String, generation: UInt64) {
        Task { @MainActor [weak self] in self?.disconnected(reason, generation: generation) }
    }

    private func authenticated(sessionID: String, generation: UInt64) {
        guard !stopped, self.generation == generation else { return }
        self.sessionID = sessionID
        sendSequence = 0
        retryFailureCount = 0
        lastResponseAt = Date()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeatTick() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
        send(.status)
    }

    private func received(_ envelope: VMGuestAgentEnvelope, generation: UInt64) {
        guard !stopped, self.generation == generation,
              envelope.operation == .status || envelope.operation == .heartbeat,
              let status = try? JSONDecoder().decode(VMGuestAgentStatus.self, from: envelope.payload)
        else { return }
        lastResponseAt = Date()
        stateChanged(.ready(VMOmarchyGuestStatus(
            agentVersion: status.agentVersion,
            hostName: status.hostName,
            addresses: status.addresses,
            capabilities: Set(status.capabilities ?? []),
            desktopSessionActive: status.desktopSessionActive ?? false
        )))
    }

    private func send(_ operation: VMGuestAgentOperation) {
        guard let sessionID, let connection else { return }
        do {
            writeLock.lock()
            defer { writeLock.unlock() }
            sendSequence &+= 1
            let authenticator = try VMGuestAgentAuthenticator(
                tokenData: enrollment.token,
                machineID: enrollment.machineID
            )
            let envelope = try authenticator.makeEnvelope(
                sessionID: sessionID,
                sequence: sendSequence,
                requestID: UUID().uuidString,
                operation: operation,
                payload: Data()
            )
            try Self.writeAll(
                descriptor: connection.fileDescriptor,
                data: VMGuestAgentFrameCodec.encode(envelope)
            )
        } catch {
            disconnected(error.localizedDescription, generation: generation)
        }
    }

    private func heartbeatTick() {
        guard Date().timeIntervalSince(lastResponseAt) <= 30 else {
            disconnected("The Guest Agent stopped responding.", generation: generation)
            return
        }
        send(.heartbeat)
    }

    private nonisolated static func writeAll(descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
    }

    private func disconnected(_ reason: String, generation: UInt64) {
        guard !stopped, self.generation == generation else { return }
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        sessionID = nil
        closeConnection()
        connection = nil
        stateChanged(.disconnected(reason))
        retryTask?.cancel()
        retryFailureCount += 1
        let delay = VMGuestAgentRetryPolicy(maximumDelay: 30).delay(afterFailureCount: retryFailureCount)
        let task = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.connect() }
        }
        retryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func closeConnection() {
        guard let connection else { return }
        _ = Darwin.shutdown(connection.fileDescriptor, SHUT_RDWR)
        connection.close()
    }
}
