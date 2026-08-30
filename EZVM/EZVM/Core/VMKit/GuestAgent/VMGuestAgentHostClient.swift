import Foundation
import Virtualization
import Darwin

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

private enum VMGuestAgentClientError: LocalizedError {
    case disconnected
    case timedOut

    var errorDescription: String? {
        switch self {
        case .disconnected: "The guest agent is disconnected."
        case .timedOut: "The guest agent did not answer the request in time."
        }
    }
}

@MainActor
final class VMGuestAgentHostClient {
    private struct PendingRequest {
        let continuation: CheckedContinuation<VMGuestAgentTransferResult, Error>
        let timeout: Task<Void, Never>
    }

    private let device: VZVirtioSocketDevice
    private let enrollment: VMGuestAgentEnrollment
    private weak var runtimeState: VMRuntimeState?
    private var connection: VZVirtioSocketConnection?
    private var retryTask: DispatchWorkItem?
    private var heartbeatTimer: Timer?
    private var stopped = false
    private let writeLock = NSLock()
    private var sendSequence: UInt64 = 0
    private var sessionID: String?
    private var liveness = VMGuestAgentLiveness()
    private var capabilities: Set<String> = []
    private var pendingRequests: [String: PendingRequest] = [:]
    private var transferTask: Task<Void, Never>?
    private let ioQueue = DispatchQueue(label: "com.everettjf.ezvm.guest-agent.read", qos: .utility)

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
        connection?.close()
        connection = nil
        sessionID = nil
        liveness.reset()
        capabilities.removeAll()
        transferTask?.cancel()
        transferTask = nil
        failPendingRequests(CancellationError())
    }

    func send(_ operation: VMGuestAgentOperation) {
        guard let sessionID else { return }
        do {
            try sendEnvelope(operation: operation, requestID: UUID().uuidString, payload: Data(), sessionID: sessionID)
        } catch {
            disconnected("Could not send \(operation.rawValue): \(error.localizedDescription)")
        }
    }

    func sendInputKey(code: UInt16, pressed: Bool) {
        sendInputEvents(VMGuestAgentInputBatch.key(code: code, pressed: pressed).events)
    }

    func sendInputEvents(_ events: [VMGuestAgentInputEvent]) {
        guard !events.isEmpty, events.count <= VMGuestAgentInputBatch.maximumEventCount,
              events.last == VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
              capabilities.contains("input-uinput-v1"), let sessionID else { return }
        do {
            let payload = try JSONEncoder().encode(VMGuestAgentInputBatch(events: events))
            try sendEnvelope(
                operation: .input, requestID: UUID().uuidString,
                payload: payload, sessionID: sessionID
            )
        } catch {
            disconnected("Could not send guest input: \(error.localizedDescription)")
        }
    }

    func upload(localURL: URL, destinationPath: String, overwrite: Bool) {
        guard transferTask == nil else {
            runtimeState?.updateGuestAgentTransfer(.failed("Another file transfer is already running."))
            return
        }
        transferTask = Task { [weak self] in
            await self?.performUpload(localURL: localURL, destinationPath: destinationPath, overwrite: overwrite)
        }
    }

    func download(sourcePath: String, destinationURL: URL) {
        guard transferTask == nil else {
            runtimeState?.updateGuestAgentTransfer(.failed("Another file transfer is already running."))
            return
        }
        transferTask = Task { [weak self] in
            await self?.performDownload(sourcePath: sourcePath, destinationURL: destinationURL)
        }
    }

    func cancelTransfer() {
        transferTask?.cancel()
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
        let descriptor = connection.fileDescriptor
        self.connection = connection
        runtimeState?.updateGuestAgent(.authenticating)
        let enrollment = enrollment
        ioQueue.async { [weak self] in self?.readLoop(descriptor: descriptor, enrollment: enrollment) }
    }

    private nonisolated func readLoop(descriptor: Int32, enrollment: VMGuestAgentEnrollment) {
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
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    usleep(10_000)
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if count == 0 { throw VMGuestAgentClientError.disconnected }
                let chunk = Data(bytes.prefix(count))
                for frame in try buffer.append(chunk) {
                    if activeSessionID == nil {
                        let hello = try VMGuestAgentFrameCodec.decode(VMGuestAgentHello.self, from: frame)
                        try authenticator.verifyHello(hello)
                        let hostNonce = VMGuestAgentAuthenticator.generateToken().base64EncodedString()
                        let welcome = try authenticator.makeWelcome(guestNonce: hello.guestNonce, hostNonce: hostNonce)
                        let established = try authenticator.sessionID(guestNonce: hello.guestNonce, hostNonce: hostNonce)
                        try writeAll(descriptor: descriptor, data: VMGuestAgentFrameCodec.encode(welcome))
                        activeSessionID = established
                        Task { @MainActor [weak self] in self?.authenticated(sessionID: established) }
                    } else if let activeSessionID {
                        let envelope = try VMGuestAgentFrameCodec.decode(VMGuestAgentEnvelope.self, from: frame)
                        try authenticator.verifyEnvelope(envelope, sessionID: activeSessionID)
                        Task { @MainActor [weak self] in self?.received(envelope) }
                    }
                }
            }
        } catch {
            Task { @MainActor [weak self] in self?.disconnected(error.localizedDescription) }
        }
    }

    private nonisolated func writeAll(descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    usleep(10_000)
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if count == 0 { throw VMGuestAgentClientError.disconnected }
                offset += count
            }
        }
    }

    private func write(_ data: Data) throws {
        guard let connection else { throw CocoaError(.fileNoSuchFile) }
        try writeAll(descriptor: connection.fileDescriptor, data: data)
    }

    private func sendEnvelope(operation: VMGuestAgentOperation, requestID: String, payload: Data, sessionID: String) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        sendSequence += 1
        let authenticator = try VMGuestAgentAuthenticator(tokenData: enrollment.token, machineID: enrollment.machineID)
        let envelope = try authenticator.makeEnvelope(
            sessionID: sessionID, sequence: sendSequence, requestID: requestID,
            operation: operation, payload: payload
        )
        try write(VMGuestAgentFrameCodec.encode(envelope))
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

    private func received(_ envelope: VMGuestAgentEnvelope) {
        guard !stopped else { return }
        liveness.markResponse()
        if envelope.operation == .heartbeat || envelope.operation == .status {
            do {
                let status = try JSONDecoder().decode(VMGuestAgentStatus.self, from: envelope.payload)
                capabilities = Set(status.capabilities ?? [])
                runtimeState?.updateGuestAgent(.ready(status))
            } catch {
                disconnected("The guest agent returned invalid status: \(error.localizedDescription)")
            }
            return
        }
        guard let pending = pendingRequests.removeValue(forKey: envelope.requestID) else { return }
        pending.timeout.cancel()
        do {
            let result = try JSONDecoder().decode(VMGuestAgentTransferResult.self, from: envelope.payload)
            pending.continuation.resume(returning: result)
        } catch {
            pending.continuation.resume(throwing: error)
        }
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
        let transferWasActive = transferTask != nil || !pendingRequests.isEmpty
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        sessionID = nil
        liveness.reset()
        capabilities.removeAll()
        transferTask?.cancel()
        transferTask = nil
        failPendingRequests(VMGuestAgentClientError.disconnected)
        if transferWasActive {
            runtimeState?.updateGuestAgentTransfer(.failed("The guest agent disconnected during transfer."))
        }
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

    private func request<T: Encodable>(_ operation: VMGuestAgentOperation, payload value: T) async throws -> VMGuestAgentTransferResult {
        guard let sessionID else { throw VMGuestAgentClientError.disconnected }
        let payload = try JSONEncoder().encode(value)
        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.expireRequest(requestID)
            }
            pendingRequests[requestID] = PendingRequest(continuation: continuation, timeout: timeout)
            do {
                try sendEnvelope(operation: operation, requestID: requestID, payload: payload, sessionID: sessionID)
            } catch {
                timeout.cancel()
                pendingRequests.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func expireRequest(_ requestID: String) {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
        pending.continuation.resume(throwing: VMGuestAgentClientError.timedOut)
    }

    private func failPendingRequests(_ error: Error) {
        let requests = pendingRequests.values
        pendingRequests.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func requireSuccess(_ result: VMGuestAgentTransferResult) throws {
        guard result.success else {
            throw NSError(domain: "EZVMGuestAgentTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: result.message])
        }
    }

    private func sendCancel(transferID: String) {
        guard let sessionID,
              let payload = try? JSONEncoder().encode(VMGuestAgentTransferID(transferID: transferID)) else { return }
        try? sendEnvelope(
            operation: .transferCancel, requestID: UUID().uuidString,
            payload: payload, sessionID: sessionID
        )
    }

    private func performUpload(localURL: URL, destinationPath: String, overwrite: Bool) async {
        let transferID = UUID().uuidString
        runtimeState?.updateGuestAgentTransfer(.preparing(name: localURL.lastPathComponent))
        do {
            try VMGuestAgentTransferValidator.validate(path: destinationPath)
            let metadata = try await Task.detached(priority: .utility) {
                try VMGuestAgentLocalFile.metadata(at: localURL)
            }.value
            try Task.checkCancellation()
            var result = try await request(.uploadStart, payload: VMGuestAgentUploadStart(
                transferID: transferID, destinationPath: destinationPath, totalBytes: metadata.size,
                sha256: metadata.sha256, overwrite: overwrite
            ))
            try requireSuccess(result)
            var offset: UInt64 = 0
            while offset < metadata.size {
                try Task.checkCancellation()
                let currentOffset = offset
                let chunk = try await Task.detached(priority: .utility) {
                    try VMGuestAgentLocalFile.readChunk(at: localURL, offset: currentOffset)
                }.value
                guard !chunk.isEmpty else { throw CocoaError(.fileReadUnknown) }
                result = try await request(.uploadChunk, payload: VMGuestAgentUploadChunk(
                    transferID: transferID, offset: offset, data: chunk
                ))
                try requireSuccess(result)
                offset = result.transferredBytes
                runtimeState?.updateGuestAgentTransfer(.transferring(
                    direction: .upload, name: localURL.lastPathComponent,
                    completedBytes: offset, totalBytes: metadata.size
                ))
            }
            result = try await request(.uploadCommit, payload: VMGuestAgentTransferID(transferID: transferID))
            try requireSuccess(result)
            runtimeState?.updateGuestAgentTransfer(.completed("Uploaded \(localURL.lastPathComponent) to \(destinationPath)."))
        } catch is CancellationError {
            sendCancel(transferID: transferID)
            runtimeState?.updateGuestAgentTransfer(.cancelled)
        } catch {
            sendCancel(transferID: transferID)
            runtimeState?.updateGuestAgentTransfer(.failed("Upload failed: \(error.localizedDescription)"))
        }
        transferTask = nil
    }

    private func performDownload(sourcePath: String, destinationURL: URL) async {
        let transferID = UUID().uuidString
        runtimeState?.updateGuestAgentTransfer(.preparing(name: destinationURL.lastPathComponent))
        var transaction: VMGuestAgentDownloadTransaction?
        do {
            try VMGuestAgentTransferValidator.validate(path: sourcePath)
            var result = try await request(.downloadInfo, payload: VMGuestAgentDownloadInfoRequest(
                transferID: transferID, sourcePath: sourcePath
            ))
            try requireSuccess(result)
            guard let totalBytes = result.totalBytes, let sha256 = result.sha256 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let download = try VMGuestAgentDownloadTransaction(
                destination: destinationURL, totalBytes: totalBytes, expectedSHA256: sha256
            )
            transaction = download
            repeat {
                try Task.checkCancellation()
                result = try await request(.downloadChunk, payload: VMGuestAgentDownloadChunkRequest(
                    transferID: transferID, offset: download.writtenBytes, length: VMGuestAgentProtocol.fileChunkBytes
                ))
                try requireSuccess(result)
                guard let offset = result.offset, let data = result.data, let eof = result.eof else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try download.append(offset: offset, data: data)
                runtimeState?.updateGuestAgentTransfer(.transferring(
                    direction: .download, name: destinationURL.lastPathComponent,
                    completedBytes: download.writtenBytes, totalBytes: totalBytes
                ))
                if eof { break }
            } while true
            try download.commit()
            runtimeState?.updateGuestAgentTransfer(.completed("Saved \(sourcePath) to \(destinationURL.path)."))
        } catch is CancellationError {
            transaction?.cancel()
            sendCancel(transferID: transferID)
            runtimeState?.updateGuestAgentTransfer(.cancelled)
        } catch {
            transaction?.cancel()
            sendCancel(transferID: transferID)
            runtimeState?.updateGuestAgentTransfer(.failed("Download failed: \(error.localizedDescription)"))
        }
        transferTask = nil
    }
}
