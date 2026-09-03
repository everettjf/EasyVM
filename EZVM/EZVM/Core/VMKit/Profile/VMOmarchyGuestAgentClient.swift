import Darwin
import CryptoKit
import Foundation
import Virtualization

public struct VMOmarchySharedFolderRoundTrip: Codable, Equatable, Sendable {
    public let observedAt: Date
    public let hostToGuestSHA256: String
    public let guestToHostSHA256: String

    public init(
        observedAt: Date,
        hostToGuestSHA256: String,
        guestToHostSHA256: String
    ) {
        self.observedAt = observedAt
        self.hostToGuestSHA256 = hostToGuestSHA256
        self.guestToHostSHA256 = guestToHostSHA256
    }
}

public enum VMOmarchySharedFolderProbeState: Equatable, Sendable {
    case notRun
    case running
    case passed(VMOmarchySharedFolderRoundTrip)
    case failed(String)
}

public struct VMOmarchyGuestStatus: Equatable, Sendable {
    public let agentVersion: String
    public let omarchyRevision: String?
    public let hostName: String
    public let addresses: [String]
    public let capabilities: Set<String>
    public let desktopSessionActive: Bool
    public let provisioningPending: Bool

    public init(
        agentVersion: String,
        omarchyRevision: String? = nil,
        hostName: String,
        addresses: [String],
        capabilities: Set<String>,
        desktopSessionActive: Bool,
        provisioningPending: Bool
    ) {
        self.agentVersion = agentVersion
        self.omarchyRevision = omarchyRevision
        self.hostName = hostName
        self.addresses = addresses
        self.capabilities = capabilities
        self.desktopSessionActive = desktopSessionActive
        self.provisioningPending = provisioningPending
    }
}

public struct VMOmarchyIntegrationAssessment: Equatable, Sendable {
    public let isReady: Bool
    public let missingCapabilities: [String]
    public let provisioningPending: Bool
    public let desktopSessionActive: Bool

    public static func evaluate(
        status: VMOmarchyGuestStatus,
        requiredCapabilities: [String]
    ) -> Self {
        let missing = Set(requiredCapabilities)
            .subtracting(status.capabilities)
            .sorted()
        return Self(
            isReady: missing.isEmpty
                && status.desktopSessionActive
                && !status.provisioningPending,
            missingCapabilities: missing,
            provisioningPending: status.provisioningPending,
            desktopSessionActive: status.desktopSessionActive
        )
    }
}

public enum VMOmarchyIntegrationState: Equatable, Sendable {
    case connecting
    case authenticating
    case ready(VMOmarchyGuestStatus)
    case disconnected(String)
}

@MainActor
public final class VMOmarchyGuestAgentClient {
    private struct PendingRequest {
        let operation: VMGuestAgentOperation
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }

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
    private var capabilities: Set<String> = []
    private var pendingRequests: [String: PendingRequest] = [:]

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
        capabilities.removeAll()
        failPendingRequests(CancellationError())
    }

    public func requestShutdown() { send(.shutdown) }
    public func requestRestart() { send(.restart) }

    /// Types a constrained US-ASCII command through the authenticated uinput
    /// channel. This is used by isolated end-to-end acceptance runs and does
    /// not expose a Guest shell or command-execution protocol.
    public func typeUSASCII(_ text: String) async throws {
        guard capabilities.contains("desktop-input-v1") else {
            throw CocoaError(.featureUnsupported)
        }
        for batch in try VMLinuxKeyboardTextEncoder.batches(for: text) {
            let result: VMGuestAgentInputResult = try await request(.input, payload: batch)
            guard result.success else {
                throw NSError(
                    domain: "EZVMOmarchyInput",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: result.message]
                )
            }
        }
    }

    /// Sends one complete Linux key chord with deterministic key-up cleanup.
    public func injectKeyChord(modifiers: [UInt16], key: UInt16) async throws {
        guard capabilities.contains("desktop-input-v1") else {
            throw CocoaError(.featureUnsupported)
        }
        var events: [VMGuestAgentInputEvent] = []
        func append(_ code: UInt16, pressed: Bool) {
            events.append(.init(type: 1, code: code, value: pressed ? 1 : 0))
            events.append(.init(type: 0, code: 0, value: 0))
        }
        modifiers.forEach { append($0, pressed: true) }
        append(key, pressed: true)
        append(key, pressed: false)
        modifiers.reversed().forEach { append($0, pressed: false) }
        let result: VMGuestAgentInputResult = try await request(
            .input,
            payload: VMGuestAgentInputBatch(events: events)
        )
        guard result.success else {
            throw NSError(
                domain: "EZVMOmarchyInput",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: result.message]
            )
        }
    }

    /// Proves both directions of the live VirtioFS mount without requiring SSH.
    /// The probe uses authenticated file-transfer requests and removes its
    /// random marker files before returning.
    public func verifySharedFolderRoundTrip(
        hostDirectory: URL,
        guestDirectory: String = "/mnt/ezvm-shared"
    ) async throws -> VMOmarchySharedFolderRoundTrip {
        guard capabilities.contains("shared-folders-v1"),
              capabilities.contains("file-transfer-v1") else {
            throw CocoaError(.featureUnsupported)
        }
        let nonce = UUID().uuidString.lowercased()
        let hostName = ".ezvm-acceptance-host-\(nonce).marker"
        let guestName = ".ezvm-acceptance-guest-\(nonce).marker"
        let hostURL = hostDirectory.appending(path: hostName)
        let guestURL = hostDirectory.appending(path: guestName)
        let hostData = Data("ezvm-host-to-guest:\(nonce)".utf8)
        let guestData = Data("ezvm-guest-to-host:\(nonce)".utf8)
        defer {
            try? FileManager.default.removeItem(at: hostURL)
            try? FileManager.default.removeItem(at: guestURL)
        }
        try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
        try hostData.write(to: hostURL, options: [.atomic])

        let downloaded = try await downloadData(
            guestPath: "\(guestDirectory)/\(hostName)"
        )
        guard downloaded == hostData else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try await uploadData(
            guestData,
            guestPath: "\(guestDirectory)/\(guestName)"
        )

        let deadline = ContinuousClock.now + .seconds(5)
        var returned: Data?
        repeat {
            returned = try? Data(contentsOf: guestURL)
            if returned == guestData { break }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        guard returned == guestData else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return VMOmarchySharedFolderRoundTrip(
            observedAt: Date(),
            hostToGuestSHA256: Self.sha256(hostData),
            guestToHostSHA256: Self.sha256(guestData)
        )
    }

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
        guard !stopped, self.generation == generation else { return }
        lastResponseAt = Date()
        if envelope.operation == .status || envelope.operation == .heartbeat {
            guard let status = try? JSONDecoder().decode(
                VMGuestAgentStatus.self, from: envelope.payload
            ) else {
                disconnected("The Guest Agent returned invalid status.", generation: generation)
                return
            }
            capabilities = Set(status.capabilities ?? [])
            stateChanged(.ready(VMOmarchyGuestStatus(
                agentVersion: status.agentVersion,
                omarchyRevision: status.omarchyRevision,
                hostName: status.hostName,
                addresses: status.addresses,
                capabilities: capabilities,
                desktopSessionActive: status.desktopSessionActive ?? false,
                provisioningPending: status.provisioningPending ?? false
            )))
            return
        }
        guard let pending = pendingRequests.removeValue(forKey: envelope.requestID) else { return }
        pending.timeout.cancel()
        guard pending.operation == envelope.operation else {
            pending.continuation.resume(throwing: CocoaError(.fileReadCorruptFile))
            return
        }
        pending.continuation.resume(returning: envelope.payload)
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

    private func request<Value: Encodable, Response: Decodable>(
        _ operation: VMGuestAgentOperation,
        payload value: Value
    ) async throws -> Response {
        guard let sessionID else { throw CocoaError(.fileNoSuchFile) }
        let payload = try JSONEncoder().encode(value)
        let requestID = UUID().uuidString
        let response: Data = try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.expireRequest(requestID)
            }
            pendingRequests[requestID] = PendingRequest(
                operation: operation,
                continuation: continuation,
                timeout: timeout
            )
            do {
                try sendEnvelope(
                    operation: operation,
                    requestID: requestID,
                    payload: payload,
                    sessionID: sessionID
                )
            } catch {
                timeout.cancel()
                pendingRequests.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
        return try JSONDecoder().decode(Response.self, from: response)
    }

    private func sendEnvelope(
        operation: VMGuestAgentOperation,
        requestID: String,
        payload: Data,
        sessionID: String
    ) throws {
        guard let connection else { throw CocoaError(.fileNoSuchFile) }
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
            requestID: requestID,
            operation: operation,
            payload: payload
        )
        try Self.writeAll(
            descriptor: connection.fileDescriptor,
            data: VMGuestAgentFrameCodec.encode(envelope)
        )
    }

    private func downloadData(guestPath: String) async throws -> Data {
        let transferID = UUID().uuidString
        do {
            var result: VMGuestAgentTransferResult = try await request(
                .downloadInfo,
                payload: VMGuestAgentDownloadInfoRequest(
                    transferID: transferID,
                    sourcePath: guestPath
                )
            )
            try Self.requireSuccess(result)
            guard let total = result.totalBytes,
                  total <= UInt64(VMGuestAgentProtocol.fileChunkBytes),
                  let expectedSHA256 = result.sha256 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var data = Data()
            repeat {
                result = try await request(
                    .downloadChunk,
                    payload: VMGuestAgentDownloadChunkRequest(
                        transferID: transferID,
                        offset: UInt64(data.count),
                        length: VMGuestAgentProtocol.fileChunkBytes
                    )
                )
                try Self.requireSuccess(result)
                guard result.offset == UInt64(data.count), let chunk = result.data else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                data.append(chunk)
                if result.eof == true { break }
            } while data.count <= VMGuestAgentProtocol.fileChunkBytes
            guard UInt64(data.count) == total, Self.sha256(data) == expectedSHA256 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return data
        } catch {
            sendTransferCancel(transferID)
            throw error
        }
    }

    private func uploadData(_ data: Data, guestPath: String) async throws {
        let transferID = UUID().uuidString
        do {
            var result: VMGuestAgentTransferResult = try await request(
                .uploadStart,
                payload: VMGuestAgentUploadStart(
                    transferID: transferID,
                    destinationPath: guestPath,
                    totalBytes: UInt64(data.count),
                    sha256: Self.sha256(data),
                    overwrite: false
                )
            )
            try Self.requireSuccess(result)
            result = try await request(
                .uploadChunk,
                payload: VMGuestAgentUploadChunk(
                    transferID: transferID,
                    offset: 0,
                    data: data
                )
            )
            try Self.requireSuccess(result)
            result = try await request(
                .uploadCommit,
                payload: VMGuestAgentTransferID(transferID: transferID)
            )
            try Self.requireSuccess(result)
        } catch {
            sendTransferCancel(transferID)
            throw error
        }
    }

    private func sendTransferCancel(_ transferID: String) {
        guard let sessionID,
              let payload = try? JSONEncoder().encode(
                VMGuestAgentTransferID(transferID: transferID)
              ) else { return }
        try? sendEnvelope(
            operation: .transferCancel,
            requestID: UUID().uuidString,
            payload: payload,
            sessionID: sessionID
        )
    }

    private static func requireSuccess(_ result: VMGuestAgentTransferResult) throws {
        guard result.success else {
            throw NSError(
                domain: "EZVMOmarchySharedFolderProbe",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: result.message]
            )
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func expireRequest(_ requestID: String) {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
        pending.continuation.resume(throwing: CocoaError(.fileReadUnknown))
    }

    private func failPendingRequests(_ error: Error) {
        let requests = pendingRequests.values
        pendingRequests.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
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
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    usleep(10_000)
                    continue
                }
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
        capabilities.removeAll()
        failPendingRequests(CocoaError(.fileReadUnknown))
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
