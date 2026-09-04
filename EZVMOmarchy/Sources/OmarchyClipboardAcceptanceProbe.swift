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
        unlockCredential: OmarchyAcceptanceUnlockCredential? = nil,
        pasteboard: NSPasteboard = .general
    ) async throws -> OmarchyClipboardRoundTrip {
        let nonce = UUID().uuidString.lowercased()
        let probeDirectory = sharedDirectory.appending(path: ".ezvm-clipboard-\(nonce)")
        let guestDirectory = "/mnt/ezvm-shared/\(probeDirectory.lastPathComponent)"
        func agentStagingURL(_ fileExtension: String) -> URL {
            sharedDirectory.appending(
                path: ".ezvm-clipboard-\(UUID().uuidString.lowercased()).\(fileExtension)"
            )
        }
        let agentHostText = agentStagingURL("txt")
        let agentHostImage = agentStagingURL("png")
        let agentGuestText = agentStagingURL("txt")
        let agentGuestImage = agentStagingURL("png")
        let agentURLs = [agentHostText, agentHostImage, agentGuestText, agentGuestImage]
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        var completed = false
        defer {
            snapshot.restore(pasteboard)
            if completed {
                try? FileManager.default.removeItem(at: probeDirectory)
            } else {
                NSLog("Omarchy clipboard probe retained failure evidence at %@", probeDirectory.path)
            }
            agentURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        }

        try FileManager.default.createDirectory(
            at: probeDirectory,
            withIntermediateDirectories: false
        )
        let hostText = "EZVM host → Omarchy 文本 \(nonce)"
        let guestText = "Omarchy guest → macOS 文本 \(nonce)"
        let image = try pngFixture()
        try Data(hostText.utf8).write(to: probeDirectory.appending(path: "host-text-input"))
        try image.write(to: probeDirectory.appending(path: "host-image-input"))
        try Data(hostText.utf8).write(to: agentHostText)
        try image.write(to: agentHostImage)
        try Data(guestText.utf8).write(to: probeDirectory.appending(path: "guest-text-input"))
        try image.write(to: probeDirectory.appending(path: "guest-image-input"))
        let script = probeScript(guestDirectory: guestDirectory)
        try Data(script.utf8).write(to: probeDirectory.appending(path: "probe.sh"))

        do {
            try await launchGuestScript(
                client: client,
                guestDirectory: guestDirectory,
                readyFile: probeDirectory.appending(path: "script-ready")
            )
        } catch ProbeError.timeout(let operation)
                    where operation == "script-ready" && unlockCredential != nil {
            // A freshly booted persistent workspace may be at the Omarchy lock screen even
            // while the compositor and Agent are already ready. The first
            // launch attempt will then have landed in the password field.
            // This recovery is acceptance-only: clear that field, submit the
            // ephemeral fixture secret, and retry the observable script gate.
            guard let unlockCredential else { throw ProbeError.timeout(operation) }
            NSLog("Omarchy clipboard probe recovering from a boot lock screen")
            try await client.injectKeyChord(modifiers: [29], key: 30)
            try await client.typeUSASCII(unlockCredential.password)
            try await client.injectKeyChord(modifiers: [], key: 28)
            try await Task.sleep(for: .seconds(3))
            try await launchGuestScript(
                client: client,
                guestDirectory: guestDirectory,
                readyFile: probeDirectory.appending(path: "script-ready")
            )
        }

        // The compositor can accept input before the SPICE clipboard
        // transport has rebound to the newly unlocked Wayland session. Wait
        // for the unprivileged Session Agent to prove both formats before
        // changing the Host pasteboard; otherwise that first change can be
        // lost during boot even though spice-vdagent appears moments later.
        do {
            try await waitUntil("Guest clipboard capabilities") {
                let capabilities = client.currentCapabilities
                return (capabilities.contains("clipboard-agent-text-v1")
                        && capabilities.contains("clipboard-agent-image-v1"))
                    || (capabilities.contains("clipboard-text-v1")
                        && capabilities.contains("clipboard-image-v1"))
            }
        } catch {
            await collectSessionDiagnostics(
                client: client,
                guestDirectory: guestDirectory,
                evidenceFile: probeDirectory.appending(path: "session-diagnostics.txt")
            )
            throw error
        }
        try await Task.sleep(for: .seconds(2))

        if client.currentCapabilities.contains("clipboard-agent-text-v1"),
           client.currentCapabilities.contains("clipboard-agent-image-v1") {
            do {
                let result = try await runAgentRoundTrip(
                    client: client,
                    sharedDirectory: sharedDirectory,
                    probeDirectory: probeDirectory,
                    hostText: hostText,
                    guestText: guestText,
                    image: image,
                    hostTextURL: agentHostText,
                    hostImageURL: agentHostImage,
                    guestTextURL: agentGuestText,
                    guestImageURL: agentGuestImage
                )
                completed = true
                return result
            } catch {
                await collectSessionDiagnostics(
                    client: client,
                    guestDirectory: guestDirectory,
                    evidenceFile: probeDirectory.appending(path: "session-diagnostics.txt")
                )
                throw error
            }
        }

        NSLog("Omarchy clipboard probe starting Host-to-Guest text")
        try publishTextFromExternalProcess(hostText)
        try await waitUntil("Host text pasteboard publication") {
            pasteboard.string(forType: .string) == hostText
        }
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
        try publishPNGFromExternalProcess(
            at: probeDirectory.appending(path: "host-image-input")
        )
        try await waitUntil("Host PNG pasteboard publication") {
            pasteboard.data(forType: .png) == image
        }
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

        let result = OmarchyClipboardRoundTrip(
            observedAt: Date(),
            hostToGuestTextSHA256: sha256(Data(hostText.utf8)),
            guestToHostTextSHA256: sha256(Data(guestText.utf8)),
            hostToGuestImageSHA256: sha256(image),
            guestToHostImageSHA256: sha256(image)
        )
        completed = true
        return result
    }

    static func probeScript(guestDirectory: String) -> String {
        """
        #!/usr/bin/env bash
        set -eu
        d='\(guestDirectory)'
        copy_until_matches() {
          expected="$1"
          output="$2"
          shift 2
          local_part="${XDG_RUNTIME_DIR:-/tmp}/ezvm-clipboard-probe.$$.part"
          local_error="${XDG_RUNTIME_DIR:-/tmp}/ezvm-clipboard-probe.$$.error"
          for _ in $(seq 1 150); do
            # wl-paste uses a zero-copy transfer path when stdout is a regular
            # file. A virtiofs destination can reject that splice even though
            # the clipboard data is valid, so capture in the Guest runtime FS
            # and then copy the verified bytes into the shared evidence path.
            if /usr/bin/wl-paste "$@" > "$local_part" 2>"$local_error" && cmp -s "$expected" "$local_part"; then
              cp "$local_part" "$output"
              rm -f "$local_part" "$local_error"
              return 0
            fi
            sleep 0.1
          done
          /usr/bin/wl-paste --list-types > "$d/guest-clipboard-types" 2>&1 || true
          cp "$local_part" "$output.last" 2>/dev/null || true
          cp "$local_error" "$output.error" 2>/dev/null || true
          rm -f "$local_part" "$local_error"
          return 1
        }
        /usr/bin/wl-copy --version > "$d/wl-copy-version" 2>&1 || true
        /usr/bin/wl-paste --version > "$d/wl-paste-version" 2>&1 || true
        touch "$d/script-ready"
        while [ ! -f "$d/host-text-go" ]; do sleep 0.1; done
        copy_until_matches "$d/host-text-input" "$d/host-text-result" --type 'text/plain;charset=utf-8' --no-newline
        while [ ! -f "$d/host-image-go" ]; do sleep 0.1; done
        copy_until_matches "$d/host-image-input" "$d/host-image-result" --type image/png
        while [ ! -f "$d/guest-text-go" ]; do sleep 0.1; done
        cat "$d/guest-text-input" | /usr/bin/wl-copy --foreground --type 'text/plain;charset=utf-8' &
        text_pid=$!
        touch "$d/guest-text-ready"
        while [ ! -f "$d/guest-text-consumed" ]; do sleep 0.1; done
        kill "$text_pid" 2>/dev/null || true
        wait "$text_pid" 2>/dev/null || true
        cat "$d/guest-image-input" | /usr/bin/wl-copy --foreground --type image/png &
        image_pid=$!
        touch "$d/guest-image-ready"
        while [ ! -f "$d/guest-image-consumed" ]; do sleep 0.1; done
        kill "$image_pid" 2>/dev/null || true
        wait "$image_pid" 2>/dev/null || true
        touch "$d/script-done"
        """
    }

    private static func launchGuestScript(
        client: VMOmarchyGuestAgentClient,
        guestDirectory: String,
        readyFile: URL
    ) async throws {
        // Omarchy's documented Super-Return shortcut opens a terminal. The
        // command itself is typed through the authenticated uinput channel.
        NSLog("Omarchy clipboard probe opening Guest terminal")
        try await client.injectKeyChord(modifiers: [125], key: 28)
        try await Task.sleep(for: .seconds(2))
        NSLog("Omarchy clipboard probe typing Guest script path %@", guestDirectory)
        try await client.typeUSASCII("bash \(guestDirectory)/probe.sh\n")
        try await waitForFile(at: readyFile)
    }

    private static func runAgentRoundTrip(
        client: VMOmarchyGuestAgentClient,
        sharedDirectory: URL,
        probeDirectory: URL,
        hostText: String,
        guestText: String,
        image: Data,
        hostTextURL: URL,
        hostImageURL: URL,
        guestTextURL: URL,
        guestImageURL: URL
    ) async throws -> OmarchyClipboardRoundTrip {
        NSLog("Omarchy Agent clipboard probe starting Host-to-Guest text")
        let hostTextRequest = try agentRequest(
            for: hostTextURL, sharedDirectory: sharedDirectory,
            mimeType: "text/plain;charset=utf-8"
        )
        _ = try await retryAgentOperation("Agent host-to-guest text") {
            try await client.setGuestClipboard(hostTextRequest)
        }
        try touch(probeDirectory.appending(path: "host-text-go"))
        let hostTextResult = try await waitForData(
            at: probeDirectory.appending(path: "host-text-result")
        )
        guard hostTextResult == Data(hostText.utf8) else {
            throw ProbeError.mismatch(
                "Agent host-to-guest text", expected: Data(hostText.utf8), actual: hostTextResult
            )
        }

        NSLog("Omarchy Agent clipboard probe starting Host-to-Guest PNG")
        let hostImageRequest = try agentRequest(
            for: hostImageURL, sharedDirectory: sharedDirectory,
            mimeType: "image/png"
        )
        _ = try await retryAgentOperation("Agent host-to-guest PNG") {
            try await client.setGuestClipboard(hostImageRequest)
        }
        try touch(probeDirectory.appending(path: "host-image-go"))
        let hostImageResult = try await waitForData(
            at: probeDirectory.appending(path: "host-image-result")
        )
        guard hostImageResult == image else {
            throw ProbeError.mismatch(
                "Agent host-to-guest PNG", expected: image, actual: hostImageResult
            )
        }

        NSLog("Omarchy Agent clipboard probe starting Guest-to-Host text")
        try touch(probeDirectory.appending(path: "guest-text-go"))
        try await waitForFile(at: probeDirectory.appending(path: "guest-text-ready"))
        let capturedText = try await retryAgentOperation("Agent guest-to-host text") {
            try await client.captureGuestClipboard(
                agentCaptureRequest(for: guestTextURL, sharedDirectory: sharedDirectory,
                                    mimeType: "text/plain;charset=utf-8")
            )
        }
        let guestTextResult = try Data(contentsOf: guestTextURL)
        guard guestTextResult == Data(guestText.utf8),
              capturedText.byteCount == UInt64(guestTextResult.count),
              capturedText.sha256 == sha256(guestTextResult) else {
            throw ProbeError.mismatch(
                "Agent guest-to-host text", expected: Data(guestText.utf8), actual: guestTextResult
            )
        }
        try touch(probeDirectory.appending(path: "guest-text-consumed"))

        NSLog("Omarchy Agent clipboard probe starting Guest-to-Host PNG")
        try await waitForFile(at: probeDirectory.appending(path: "guest-image-ready"))
        let capturedImage = try await retryAgentOperation("Agent guest-to-host PNG") {
            try await client.captureGuestClipboard(
                agentCaptureRequest(for: guestImageURL, sharedDirectory: sharedDirectory,
                                    mimeType: "image/png")
            )
        }
        let guestImageResult = try Data(contentsOf: guestImageURL)
        guard guestImageResult == image,
              capturedImage.byteCount == UInt64(guestImageResult.count),
              capturedImage.sha256 == sha256(guestImageResult) else {
            throw ProbeError.mismatch(
                "Agent guest-to-host PNG", expected: image, actual: guestImageResult
            )
        }
        try touch(probeDirectory.appending(path: "guest-image-consumed"))
        try await waitForFile(at: probeDirectory.appending(path: "script-done"))

        return OmarchyClipboardRoundTrip(
            observedAt: Date(),
            hostToGuestTextSHA256: sha256(Data(hostText.utf8)),
            guestToHostTextSHA256: sha256(guestTextResult),
            hostToGuestImageSHA256: sha256(image),
            guestToHostImageSHA256: sha256(guestImageResult)
        )
    }

    private static func agentRequest(
        for url: URL,
        sharedDirectory: URL,
        mimeType: String
    ) throws -> VMOmarchyClipboardRequest {
        let data = try Data(contentsOf: url)
        return VMOmarchyClipboardRequest(
            relativePath: relativeClipboardPath(for: url, sharedDirectory: sharedDirectory),
            mimeType: mimeType,
            byteCount: UInt64(data.count),
            sha256: sha256(data)
        )
    }

    private static func retryAgentOperation<T>(
        _ operation: String,
        action: () async throws -> T
    ) async throws -> T {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastError: Error?
        repeat {
            do {
                return try await action()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(250))
            }
        } while clock.now < deadline
        throw ProbeError.timeout("\(operation): \(lastError?.localizedDescription ?? "unknown error")")
    }

    private static func collectSessionDiagnostics(
        client: VMOmarchyGuestAgentClient,
        guestDirectory: String,
        evidenceFile: URL
    ) async {
        do {
            // Stop the probe script that is waiting in the foreground, then
            // collect only service/process/socket state. This acceptance-only
            // path avoids taking over the developer's physical keyboard.
            try await client.injectKeyChord(modifiers: [29], key: 46)
            try await Task.sleep(for: .milliseconds(500))
            let command = "{ systemctl --user status ezvm-session-agent.service --no-pager; journalctl --user -u ezvm-session-agent.service --no-pager -n 100; systemctl --user show ezvm-session-agent.service -p ActiveState -p SubState -p NRestarts -p ExecMainStatus; ps -ef | grep '[e]zvm-agent'; ls -ld /run/ezvm-agent/sessions; ls -l /run/ezvm-agent/sessions/session-1000.sock /run/ezvm-agent/session.sock; } > \(guestDirectory)/session-diagnostics.txt 2>&1\n"
            try await client.typeUSASCII(command)
            try await waitForFile(at: evidenceFile)
            NSLog("Omarchy clipboard probe captured Guest session diagnostics at %@", evidenceFile.path)
        } catch {
            NSLog("Omarchy clipboard probe could not capture Guest session diagnostics: %@", error.localizedDescription)
        }
    }

    private static func agentCaptureRequest(
        for url: URL,
        sharedDirectory: URL,
        mimeType: String
    ) -> VMOmarchyClipboardRequest {
        VMOmarchyClipboardRequest(
            relativePath: relativeClipboardPath(for: url, sharedDirectory: sharedDirectory),
            mimeType: mimeType,
            byteCount: 0,
            sha256: ""
        )
    }

    private static func relativeClipboardPath(for url: URL, sharedDirectory: URL) -> String {
        String(url.path.dropFirst(sharedDirectory.path.count + 1))
    }

    private static func publishTextFromExternalProcess(_ text: String) throws {
        let input = Pipe()
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pbcopy")
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(text.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProbeError.pasteboardWrite("text")
        }
    }

    private static func publishPNGFromExternalProcess(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "on run argv",
            "-e",
            "set the clipboard to (read POSIX file (item 1 of argv) as «class PNGf»)",
            "-e",
            "end run",
            url.path
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
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
