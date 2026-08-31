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
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }

    private let device: VZVirtioSocketDevice
    private let enrollment: VMGuestAgentEnrollment
    private weak var runtimeState: VMRuntimeState?
    private let onInputCapabilitiesChanged: (Bool) -> Void
    private var connection: VZVirtioSocketConnection?
    private var connectionGeneration: UInt64 = 0
    private var retryTask: DispatchWorkItem?
    private var heartbeatTimer: Timer?
    private var stopped = false
    private let writeLock = NSLock()
    private var sendSequence: UInt64 = 0
    private var sessionID: String?
    private var liveness = VMGuestAgentLiveness()
    private var capabilities: Set<String> = []
    private var pendingRequests: [String: PendingRequest] = [:]
    private var pendingInputBatches: [[VMGuestAgentInputEvent]] = []
    private var inputTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?
    private let ioQueue = DispatchQueue(label: "com.everettjf.ezvm.guest-agent.read", qos: .utility)

    init(
        device: VZVirtioSocketDevice,
        enrollment: VMGuestAgentEnrollment,
        runtimeState: VMRuntimeState,
        onInputCapabilitiesChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.device = device
        self.enrollment = enrollment
        self.runtimeState = runtimeState
        self.onInputCapabilitiesChanged = onInputCapabilitiesChanged
    }

    func start() {
        guard !stopped else { return }
        runtimeState?.updateGuestAgent(.connecting)
        connect()
    }

    func stop() {
        stopped = true
        connectionGeneration &+= 1
        retryTask?.cancel()
        retryTask = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        closeConnection()
        connection = nil
        sessionID = nil
        liveness.reset()
        capabilities.removeAll()
        onInputCapabilitiesChanged(false)
        transferTask?.cancel()
        transferTask = nil
        inputTask?.cancel()
        inputTask = nil
        pendingInputBatches.removeAll()
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
              capabilities.contains("input-uinput-v1"), sessionID != nil else { return }
        pendingInputBatches.append(events)
        guard inputTask == nil else { return }
        inputTask = Task { [weak self] in
            await self?.drainInputQueue()
        }
    }

    private func drainInputQueue() async {
        defer { inputTask = nil }
        while !Task.isCancelled, !pendingInputBatches.isEmpty {
            // Coalesce bursts into one authenticated request. This keeps key
            // down/up pairs ordered, reduces tiny AF_VSOCK writes, and—unlike
            // the former fire-and-forget path—waits for /dev/uinput to confirm
            // that the complete batch was accepted before advancing.
            await Task.yield()
            var events: [VMGuestAgentInputEvent] = []
            while let next = pendingInputBatches.first,
                  events.count + next.count <= VMGuestAgentInputBatch.maximumEventCount {
                events.append(contentsOf: next)
                pendingInputBatches.removeFirst()
            }
            do {
                let result: VMGuestAgentInputResult = try await request(
                    .input, payload: VMGuestAgentInputBatch(events: events)
                )
                guard result.success else {
                    throw NSError(
                        domain: "EZVMGuestInput", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: result.message]
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                pendingInputBatches.removeAll()
                disconnected("Could not inject guest input: \(error.localizedDescription)")
                return
            }
        }
    }

    func verifyInputInjection() async throws {
        guard capabilities.contains("input-uinput-v1") else {
            throw NSError(
                domain: "EZVMGuestInput", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Guest Agent does not advertise input-uinput-v1."]
            )
        }
        // A zero-distance relative event is intentionally invisible to the
        // desktop while still proving that the Agent can write a complete
        // event batch to the real /dev/uinput device.
        let result: VMGuestAgentInputResult = try await request(.input, payload: VMGuestAgentInputBatch(events: [
            VMGuestAgentInputEvent(type: 2, code: 0, value: 0),
            VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
        ]))
        guard result.success else {
            throw NSError(
                domain: "EZVMGuestInput", code: 2,
                userInfo: [NSLocalizedDescriptionKey: result.message]
            )
        }
    }

    /// Injects a harmless, visible keyboard fixture for the release smoke test.
    /// Focuses the center-lower password field, spells `hello`, then submits it.
    /// The intentionally wrong password produces a visible login failure without
    /// exposing or changing any user data.
    func injectVisibleInputFixture() async throws {
        let keyCodes: [UInt16] = [35, 18, 38, 38, 24, 28]
        var events: [VMGuestAgentInputEvent] = [
            VMGuestAgentInputEvent(type: 3, code: 0, value: 16_384),
            VMGuestAgentInputEvent(type: 3, code: 1, value: 22_500),
            VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
            VMGuestAgentInputEvent(type: 1, code: 272, value: 1),
            VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
            VMGuestAgentInputEvent(type: 1, code: 272, value: 0),
            VMGuestAgentInputEvent(type: 0, code: 0, value: 0),
        ]
        for code in keyCodes {
            events.append(VMGuestAgentInputEvent(type: 1, code: code, value: 1))
            events.append(VMGuestAgentInputEvent(type: 0, code: 0, value: 0))
            events.append(VMGuestAgentInputEvent(type: 1, code: code, value: 0))
            events.append(VMGuestAgentInputEvent(type: 0, code: 0, value: 0))
        }
        let result: VMGuestAgentInputResult = try await request(
            .input, payload: VMGuestAgentInputBatch(events: events)
        )
        guard result.success else {
            throw NSError(
                domain: "EZVMGuestInput", code: 4,
                userInfo: [NSLocalizedDescriptionKey: result.message]
            )
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
        connectionGeneration &+= 1
        let generation = connectionGeneration
        device.connect(toPort: VMGuestAgentProtocol.port) { [weak self] result in
            Task { @MainActor in
                guard let self, !self.stopped,
                      self.connectionGeneration == generation else { return }
                switch result {
                case .success(let connection): self.begin(connection, generation: generation)
                case .failure(let error): self.scheduleRetry(error.localizedDescription)
                }
            }
        }
    }

    private func begin(_ connection: VZVirtioSocketConnection, generation: UInt64) {
        let descriptor = connection.fileDescriptor
        self.connection = connection
        runtimeState?.updateGuestAgent(.authenticating)
        let enrollment = enrollment
        ioQueue.async { [weak self] in
            self?.readLoop(descriptor: descriptor, enrollment: enrollment, generation: generation)
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
            authenticator = try VMGuestAgentAuthenticator(tokenData: enrollment.token, machineID: enrollment.machineID)
        } catch {
            Task { @MainActor [weak self] in
                self?.disconnected(error.localizedDescription, generation: generation)
            }
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
            Task { @MainActor [weak self] in
                self?.disconnected(error.localizedDescription, generation: generation)
            }
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

    private func authenticated(sessionID: String, generation: UInt64) {
        guard !stopped, connectionGeneration == generation else { return }
        self.sessionID = sessionID
        sendSequence = 0
        liveness.markResponse()
        heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeatTick() }
        }
        timer.tolerance = 2
        // Menus, window drags, full-screen transitions, and pointer capture can
        // move AppKit out of the default run-loop mode for long enough to trip
        // the 30-second liveness deadline. Keep the control channel alive in
        // common modes just like the VM screenshot timer.
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
        send(.status)
    }

    private func received(_ envelope: VMGuestAgentEnvelope, generation: UInt64) {
        guard !stopped, connectionGeneration == generation else { return }
        liveness.markResponse()
        if envelope.operation == .heartbeat || envelope.operation == .status {
            do {
                let status = try JSONDecoder().decode(VMGuestAgentStatus.self, from: envelope.payload)
                capabilities = Set(status.capabilities ?? [])
                onInputCapabilitiesChanged(status.supportsAbsoluteGuestPointer)
                runtimeState?.updateGuestAgent(.ready(status))
            } catch {
                disconnected("The guest agent returned invalid status: \(error.localizedDescription)")
            }
            return
        }
        guard let pending = pendingRequests.removeValue(forKey: envelope.requestID) else { return }
        pending.timeout.cancel()
        pending.continuation.resume(returning: envelope.payload)
    }

    private func heartbeatTick(now: Date = Date()) {
        guard !liveness.hasExpired(at: now) else {
            disconnected("The guest agent stopped responding.")
            return
        }
        send(.heartbeat)
    }

    private func disconnected(_ reason: String) {
        disconnected(reason, generation: connectionGeneration)
    }

    private func disconnected(_ reason: String, generation: UInt64) {
        guard connectionGeneration == generation else { return }
        guard !stopped else { return }
        let transferWasActive = transferTask != nil || !pendingRequests.isEmpty
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        sessionID = nil
        liveness.reset()
        capabilities.removeAll()
        onInputCapabilitiesChanged(false)
        transferTask?.cancel()
        transferTask = nil
        inputTask?.cancel()
        inputTask = nil
        pendingInputBatches.removeAll()
        failPendingRequests(VMGuestAgentClientError.disconnected)
        if transferWasActive {
            runtimeState?.updateGuestAgentTransfer(.failed("The guest agent disconnected during transfer."))
        }
        closeConnection()
        connection = nil
        runtimeState?.updateGuestAgent(.disconnected(reason))
        scheduleRetry(reason)
    }

    private func closeConnection() {
        guard let connection else { return }
        // Closing a descriptor from another thread does not reliably wake a
        // blocking read on Darwin. Shutdown first so the old reader exits and
        // cannot linger into the next connection generation.
        _ = Darwin.shutdown(connection.fileDescriptor, SHUT_RDWR)
        connection.close()
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

    private func request<T: Encodable, Response: Decodable>(
        _ operation: VMGuestAgentOperation, payload value: T
    ) async throws -> Response {
        guard let sessionID else { throw VMGuestAgentClientError.disconnected }
        let payload = try JSONEncoder().encode(value)
        let requestID = UUID().uuidString
        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
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
        return try JSONDecoder().decode(Response.self, from: responseData)
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
            var result: VMGuestAgentTransferResult = try await request(.uploadStart, payload: VMGuestAgentUploadStart(
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
            var result: VMGuestAgentTransferResult = try await request(.downloadInfo, payload: VMGuestAgentDownloadInfoRequest(
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
