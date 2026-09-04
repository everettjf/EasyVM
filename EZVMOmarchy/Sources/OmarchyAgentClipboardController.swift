import AppKit
import CryptoKit
import EZVMCore
import Foundation

@MainActor
final class OmarchyAgentClipboardController {
    static let maximumBytes = 100 * 1024 * 1024
    static let textMIME = "text/plain;charset=utf-8"
    static let imageMIME = "image/png"

    private struct Item {
        let data: Data
        let mimeType: String
        let fileExtension: String

        var fingerprint: String {
            "\(mimeType):\(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())"
        }
    }

    private let client: VMOmarchyGuestAgentClient
    private let sharedDirectory: URL
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var operationTask: Task<Void, Never>?
    private var lastPasteboardChangeCount: Int
    private var lastSentToGuest: String?
    private var lastReceivedFromGuest: String?
    private var pendingHostItem: Item?

    init(
        client: VMOmarchyGuestAgentClient,
        sharedDirectory: URL,
        pasteboard: NSPasteboard = .general
    ) {
        self.client = client
        self.sharedDirectory = sharedDirectory
        self.pasteboard = pasteboard
        lastPasteboardChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        operationTask?.cancel()
        operationTask = nil
    }

    private func tick() {
        guard operationTask == nil else { return }
        if pasteboard.changeCount != lastPasteboardChangeCount {
            lastPasteboardChangeCount = pasteboard.changeCount
            pendingHostItem = nil
            guard let item = Self.item(from: pasteboard),
                  item.fingerprint != lastReceivedFromGuest else { return }
            pendingHostItem = item
        }
        if let item = pendingHostItem {
            operationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.operationTask = nil }
                do {
                    try await self.sendToGuest(item)
                    self.lastSentToGuest = item.fingerprint
                    if self.pendingHostItem?.fingerprint == item.fingerprint {
                        self.pendingHostItem = nil
                    }
                } catch is CancellationError {
                } catch {
                    NSLog("Omarchy Agent Host-to-Guest clipboard failed: %@", error.localizedDescription)
                }
            }
            return
        }
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.operationTask = nil }
            do {
                if let item = try await self.captureFromGuest(),
                   item.fingerprint != self.lastSentToGuest,
                   item.fingerprint != self.lastReceivedFromGuest {
                    try Self.publish(item, on: self.pasteboard)
                    self.lastReceivedFromGuest = item.fingerprint
                    self.lastPasteboardChangeCount = self.pasteboard.changeCount
                }
            } catch is CancellationError {
            } catch {
                // A requested format can be absent while the other one is
                // active. Capture failures are transient and must not tear
                // down the authenticated integration connection.
            }
        }
    }

    private func sendToGuest(_ item: Item) async throws {
        let url = try stagingURL(fileExtension: item.fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        try item.data.write(to: url, options: [.atomic])
        let digest = SHA256.hash(data: item.data).map { String(format: "%02x", $0) }.joined()
        _ = try await client.setGuestClipboard(VMOmarchyClipboardRequest(
            relativePath: relativePath(for: url),
            mimeType: item.mimeType,
            byteCount: UInt64(item.data.count),
            sha256: digest
        ))
    }

    private func captureFromGuest() async throws -> Item? {
        if let image = try? await capture(mimeType: Self.imageMIME, fileExtension: "png"),
           NSBitmapImageRep(data: image) != nil {
            return Item(data: image, mimeType: Self.imageMIME, fileExtension: "png")
        }
        guard let text = try? await capture(mimeType: Self.textMIME, fileExtension: "txt"),
              text.count <= Self.maximumBytes,
              String(data: text, encoding: .utf8) != nil else { return nil }
        return Item(data: text, mimeType: Self.textMIME, fileExtension: "txt")
    }

    private func capture(mimeType: String, fileExtension: String) async throws -> Data {
        let url = try stagingURL(fileExtension: fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await client.captureGuestClipboard(VMOmarchyClipboardRequest(
            relativePath: relativePath(for: url),
            mimeType: mimeType,
            byteCount: 0,
            sha256: ""
        ))
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= Self.maximumBytes,
              result.byteCount == UInt64(data.count),
              result.sha256 == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
        else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    private func stagingURL(fileExtension: String) throws -> URL {
        let directory = sharedDirectory.appending(path: ".ezvm-integration/clipboard")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(UUID().uuidString.lowercased()).\(fileExtension)")
    }

    private func relativePath(for url: URL) -> String {
        String(url.path.dropFirst(sharedDirectory.path.count + 1))
    }

    private static func item(from pasteboard: NSPasteboard) -> Item? {
        if let data = pasteboard.data(forType: .png),
           !data.isEmpty, data.count <= maximumBytes,
           NSBitmapImageRep(data: data) != nil {
            return Item(data: data, mimeType: imageMIME, fileExtension: "png")
        }
        guard let value = pasteboard.string(forType: .string) else { return nil }
        let data = Data(value.utf8)
        guard data.count <= maximumBytes else { return nil }
        return Item(data: data, mimeType: textMIME, fileExtension: "txt")
    }

    private static func publish(_ item: Item, on pasteboard: NSPasteboard) throws {
        pasteboard.clearContents()
        let succeeded: Bool
        switch item.mimeType {
        case imageMIME:
            succeeded = pasteboard.setData(item.data, forType: .png)
        case textMIME:
            guard let value = String(data: item.data, encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            succeeded = pasteboard.setString(value, forType: .string)
        default:
            throw CocoaError(.featureUnsupported)
        }
        guard succeeded else { throw CocoaError(.fileWriteUnknown) }
    }
}
