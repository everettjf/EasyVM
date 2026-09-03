import AppKit
import CryptoKit
import EZVMCore
import Foundation

struct OmarchyClipboardRoundTrip: Codable, Equatable {
    let observedAt: Date
    let hostToGuestTextSHA256: String
    let guestToHostTextSHA256: String
    let hostToGuestImageSHA256: String
    let guestToHostImageSHA256: String
}

enum OmarchyClipboardProbeState: Equatable {
    case notRun
    case running
    case passed(OmarchyClipboardRoundTrip)
    case failed(String)
}

@MainActor
enum OmarchyClipboardAcceptanceProbe {
    private static let timeout: Duration = .seconds(20)

    static func run(
        client: VMOmarchyGuestAgentClient,
        sharedDirectory: URL,
        pasteboard: NSPasteboard = .general
    ) async throws -> OmarchyClipboardRoundTrip {
        let nonce = UUID().uuidString.lowercased()
        let probeDirectory = sharedDirectory.appending(path: ".ezvm-clipboard-\(nonce)")
        let guestDirectory = "/mnt/ezvm-shared/\(probeDirectory.lastPathComponent)"
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        defer {
            snapshot.restore(pasteboard)
            try? FileManager.default.removeItem(at: probeDirectory)
        }

        try FileManager.default.createDirectory(
            at: probeDirectory,
            withIntermediateDirectories: false
        )
        let hostText = "EZVM host → Omarchy 文本 \(nonce)"
        let guestText = "Omarchy guest → macOS 文本 \(nonce)"
        let image = try pngFixture()
        try Data(guestText.utf8).write(to: probeDirectory.appending(path: "guest-text-input"))
        try image.write(to: probeDirectory.appending(path: "guest-image-input"))
        let script = probeScript(guestDirectory: guestDirectory)
        try Data(script.utf8).write(to: probeDirectory.appending(path: "probe.sh"))

        // Omarchy's documented Super-Return shortcut opens a terminal. The
        // command itself is typed through the authenticated uinput channel.
        NSLog("Omarchy clipboard probe opening Guest terminal")
        try await client.injectKeyChord(modifiers: [125], key: 28)
        try await Task.sleep(for: .seconds(2))
        NSLog("Omarchy clipboard probe typing Guest script path %@", guestDirectory)
        try await client.typeUSASCII("bash \(guestDirectory)/probe.sh\n")

        NSLog("Omarchy clipboard probe starting Host-to-Guest text")
        try setText(hostText, on: pasteboard)
        try touch(probeDirectory.appending(path: "host-text-go"))
        let hostTextResult = try await waitForData(
            at: probeDirectory.appending(path: "host-text-result")
        )
        guard hostTextResult == Data(hostText.utf8) else {
            throw ProbeError.mismatch(
                "host-to-guest text",
                expected: Data(hostText.utf8),
                actual: hostTextResult
            )
        }

        NSLog("Omarchy clipboard probe starting Host-to-Guest PNG")
        try setPNG(image, on: pasteboard)
        try touch(probeDirectory.appending(path: "host-image-go"))
        let hostImageResult = try await waitForData(
            at: probeDirectory.appending(path: "host-image-result")
        )
        guard hostImageResult == image else {
            throw ProbeError.mismatch("host-to-guest PNG", expected: image, actual: hostImageResult)
        }

        NSLog("Omarchy clipboard probe starting Guest-to-Host text")
        try touch(probeDirectory.appending(path: "guest-text-go"))
        try await waitForFile(at: probeDirectory.appending(path: "guest-text-ready"))
        try await waitUntil("guest-to-host text") {
            pasteboard.string(forType: .string) == guestText
        }
        try touch(probeDirectory.appending(path: "guest-text-consumed"))

        NSLog("Omarchy clipboard probe starting Guest-to-Host PNG")
        try await waitForFile(at: probeDirectory.appending(path: "guest-image-ready"))
        try await waitUntil("guest-to-host PNG") {
            pasteboard.data(forType: .png) == image
        }
        try touch(probeDirectory.appending(path: "guest-image-consumed"))
        try await waitForFile(at: probeDirectory.appending(path: "script-done"))
        try await Task.sleep(for: .milliseconds(250))

        return OmarchyClipboardRoundTrip(
            observedAt: Date(),
            hostToGuestTextSHA256: sha256(Data(hostText.utf8)),
            guestToHostTextSHA256: sha256(Data(guestText.utf8)),
            hostToGuestImageSHA256: sha256(image),
            guestToHostImageSHA256: sha256(image)
        )
    }

    private static func probeScript(guestDirectory: String) -> String {
        """
        #!/usr/bin/env bash
        set -eu
        d='\(guestDirectory)'
        while [ ! -f "$d/host-text-go" ]; do sleep 0.1; done
        sleep 1
        wl-paste --no-newline > "$d/host-text-result"
        while [ ! -f "$d/host-image-go" ]; do sleep 0.1; done
        sleep 1
        wl-paste --type image/png > "$d/host-image-result"
        while [ ! -f "$d/guest-text-go" ]; do sleep 0.1; done
        wl-copy --type 'text/plain;charset=utf-8' < "$d/guest-text-input" &
        text_pid=$!
        touch "$d/guest-text-ready"
        while [ ! -f "$d/guest-text-consumed" ]; do sleep 0.1; done
        kill "$text_pid" 2>/dev/null || true
        wait "$text_pid" 2>/dev/null || true
        wl-copy --type image/png < "$d/guest-image-input" &
        image_pid=$!
        touch "$d/guest-image-ready"
        while [ ! -f "$d/guest-image-consumed" ]; do sleep 0.1; done
        kill "$image_pid" 2>/dev/null || true
        wait "$image_pid" 2>/dev/null || true
        touch "$d/script-done"
        """
    }

    private static func setText(_ text: String, on pasteboard: NSPasteboard) throws {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw ProbeError.pasteboardWrite("text")
        }
    }

    private static func setPNG(_ data: Data, on pasteboard: NSPasteboard) throws {
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else {
            throw ProbeError.pasteboardWrite("PNG")
        }
    }

    private static func touch(_ url: URL) throws {
        try Data().write(to: url, options: .atomic)
    }

    private static func waitForData(at url: URL) async throws -> Data {
        var result: Data?
        try await waitUntil(url.lastPathComponent) {
            result = try? Data(contentsOf: url)
            return result != nil
        }
        return result ?? Data()
    }

    private static func waitForFile(at url: URL) async throws {
        try await waitUntil(url.lastPathComponent) {
            FileManager.default.fileExists(atPath: url.path)
        }
    }

    private static func waitUntil(
        _ operation: String,
        predicate: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        repeat {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw ProbeError.timeout(operation)
    }

    private static func pngFixture() throws -> Data {
        guard let data = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR42mNkYPj/n4GBgYGJAQoAHgQCAf2x0ksAAAAASUVORK5CYII="
        ), NSBitmapImageRep(data: data) != nil else {
            throw ProbeError.invalidFixture
        }
        return data
    }

    nonisolated private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    enum ProbeError: LocalizedError {
        case invalidFixture
        case mismatch(String, expected: Data, actual: Data)
        case pasteboardWrite(String)
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .invalidFixture: "The clipboard PNG fixture is invalid."
            case .mismatch(let operation, let expected, let actual):
                "Clipboard \(operation) data did not match (expected \(expected.count) bytes/\(sha256(expected)), actual \(actual.count) bytes/\(sha256(actual)))."
            case .pasteboardWrite(let type): "Could not write \(type) to the macOS pasteboard."
            case .timeout(let operation): "Timed out waiting for clipboard \(operation)."
            }
        }
    }
}

private struct PasteboardSnapshot {
    struct Item {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    let items: [Item]

    static func capture(_ pasteboard: NSPasteboard) -> Self {
        Self(items: (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        })
    }

    func restore(_ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { snapshot in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.values { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
