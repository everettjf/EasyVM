import Foundation
import Virtualization

enum VMGuestAgentConnectionState: Equatable {
    case unavailable
    case notEnrolled
    case connecting
    case authenticating
    case ready(VMGuestAgentStatus)
    case disconnected(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

@MainActor
final class VMGuestAgentHostClient {
    private let device: VZVirtioSocketDevice
    private let enrollment: VMGuestAgentEnrollment
    private weak var runtimeState: VMRuntimeState?
    private var connection: VZVirtioSocketConnection?
    private var fileHandle: FileHandle?
    private var retryTask: DispatchWorkItem?
    private var heartbeatTimer: Timer?
    private var stopped = false
    private let writeLock = NSLock()
    private var sendSequence: UInt64 = 0
    private var sessionID: String?
    private var liveness = VMGuestAgentLiveness()
    private let ioQueue = DispatchQueue(label: "com.everettjf.easyvm.guest-agent.read", qos: .utility)

    init(device: VZVirtioSocketDevice, enrollment: VMGuestAgentEnrollment, runtimeState: VMRuntimeState) {
        self.device = device
        self.enrollment = enrollment
        self.runtimeState = runtimeState
    }

    func start() {
        guard !stopped else { return }
        runtimeState?.updateGuestAgent(.connecting)
        connect()
    }

    func stop() {
        stopped = true
        retryTask?.cancel()
        retryTask = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        fileHandle?.closeFile()
        fileHandle = nil
        connection?.close()
        connection = nil
        sessionID = nil
        liveness.reset()
    }

    func send(_ operation: VMGuestAgentOperation) {
        guard let sessionID else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            sendSequence += 1
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
            try write(VMGuestAgentFrameCodec.encode(envelope))
        } catch {
            disconnected("Could not send \(operation.rawValue): \(error.localizedDescription)")
        }
    }

    private func connect() {
        guard !stopped else { return }
        device.connect(toPort: VMGuestAgentProtocol.port) { [weak self] result in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                switch result {
                case .success(let connection): self.begin(connection)
                case .failure(let error): self.scheduleRetry(error.localizedDescription)
                }
            }
        }
    }

    private func begin(_ connection: VZVirtioSocketConnection) {
        self.connection = connection
        fileHandle = FileHandle(fileDescriptor: connection.fileDescriptor, closeOnDealloc: false)
        runtimeState?.updateGuestAgent(.authenticating)
        let handle = fileHandle
        let enrollment = enrollment
        ioQueue.async { [weak self] in self?.readLoop(handle: handle, enrollment: enrollment) }
    }

    private nonisolated func readLoop(handle: FileHandle?, enrollment: VMGuestAgentEnrollment) {
        guard let handle else { return }
        var buffer = VMGuestAgentFrameBuffer()
        var authenticator: VMGuestAgentAuthenticator
        do {
            authenticator = try VMGuestAgentAuthenticator(tokenData: enrollment.token, machineID: enrollment.machineID)
        } catch {
            Task { @MainActor [weak self] in self?.disconnected(error.localizedDescription) }
            return
        }
        var activeSessionID: String?
        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                for frame in try buffer.append(chunk) {
                    if activeSessionID == nil {
                        let hello = try VMGuestAgentFrameCodec.decode(VMGuestAgentHello.self, from: frame)
                        try authenticator.verifyHello(hello)
                        let hostNonce = VMGuestAgentAuthenticator.generateToken().base64EncodedString()
                        let welcome = try authenticator.makeWelcome(guestNonce: hello.guestNonce, hostNonce: hostNonce)
                        let established = try authenticator.sessionID(guestNonce: hello.guestNonce, hostNonce: hostNonce)
                        try handle.write(contentsOf: VMGuestAgentFrameCodec.encode(welcome))
                        activeSessionID = established
                        Task { @MainActor [weak self] in self?.authenticated(sessionID: established) }
                    } else if let activeSessionID {
                        let envelope = try VMGuestAgentFrameCodec.decode(VMGuestAgentEnvelope.self, from: frame)
                        try authenticator.verifyEnvelope(envelope, sessionID: activeSessionID)
                        if envelope.operation == .heartbeat || envelope.operation == .status {
                            let status = try JSONDecoder().decode(VMGuestAgentStatus.self, from: envelope.payload)
                            Task { @MainActor [weak self] in self?.received(status) }
                        }
                    }
                }
            }
            throw CocoaError(.fileReadUnknown)
        } catch {
            Task { @MainActor [weak self] in self?.disconnected(error.localizedDescription) }
        }
    }

    private func write(_ data: Data) throws {
        guard let handle = fileHandle else { throw CocoaError(.fileNoSuchFile) }
        try handle.write(contentsOf: data)
    }

    private func authenticated(sessionID: String) {
        guard !stopped else { return }
        self.sessionID = sessionID
        sendSequence = 0
        liveness.markResponse()
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeatTick() }
        }
        heartbeatTimer?.tolerance = 2
        send(.status)
    }

    private func received(_ status: VMGuestAgentStatus) {
        guard !stopped else { return }
        liveness.markResponse()
        runtimeState?.updateGuestAgent(.ready(status))
    }

    private func heartbeatTick(now: Date = Date()) {
        guard !liveness.hasExpired(at: now) else {
            disconnected("The guest agent stopped responding.")
            return
        }
        send(.heartbeat)
    }

    private func disconnected(_ reason: String) {
        guard !stopped else { return }
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        sessionID = nil
        liveness.reset()
        fileHandle?.closeFile()
        fileHandle = nil
        connection?.close()
        connection = nil
        runtimeState?.updateGuestAgent(.disconnected(reason))
        scheduleRetry(reason)
    }

    private func scheduleRetry(_ reason: String) {
        guard !stopped else { return }
        runtimeState?.updateGuestAgent(.disconnected(reason))
        retryTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.runtimeState?.updateGuestAgent(.connecting)
                self.connect()
            }
        }
        retryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }
}
