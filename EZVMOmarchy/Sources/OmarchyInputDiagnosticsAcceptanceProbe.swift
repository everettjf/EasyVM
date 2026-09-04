import EZVMCore
import Foundation

@MainActor
enum OmarchyInputDiagnosticsAcceptanceProbe {
    struct LockCycle: Equatable {
        let lockedAt: Date
        let unlockedAt: Date
    }

    enum ProbeError: LocalizedError {
        case timeout
        case shortcutUnavailable

        var errorDescription: String? {
            switch self {
            case .timeout:
                "The Guest did not return Hyprland input diagnostics."
            case .shortcutUnavailable:
                "The focused Accessibility Command bridge could not send the lock shortcut."
            }
        }
    }

    private static let timeout: Duration = .seconds(20)

    static func run(
        client: VMOmarchyGuestAgentClient,
        sharedDirectory: URL,
        diagnosticsDirectory: URL
    ) async throws {
        let nonce = UUID().uuidString.lowercased()
        let stem = ".ezvm-input-diagnostics-\(nonce)"
        let scriptURL = sharedDirectory.appending(path: "\(stem).sh")
        let resultURL = sharedDirectory.appending(path: "\(stem).txt")
        let guestScript = "/mnt/ezvm-shared/\(scriptURL.lastPathComponent)"
        let guestResult = "/mnt/ezvm-shared/\(resultURL.lastPathComponent)"
        let retainedResult = diagnosticsDirectory.appending(path: "lock-input-diagnostics.txt")

        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: resultURL)
        }
        try FileManager.default.createDirectory(
            at: diagnosticsDirectory,
            withIntermediateDirectories: true
        )
        try Data(probeScript(resultPath: guestResult).utf8).write(to: scriptURL, options: .atomic)

        // Omarchy's documented Super-Return binding opens the terminal. The
        // acceptance-only command then runs entirely inside the Guest and
        // writes its bounded diagnostics through the managed shared folder.
        try await client.injectKeyChord(modifiers: [125], key: 28)
        try await Task.sleep(for: .seconds(2))
        try await client.typeUSASCII("bash \(guestScript)\n")

        let deadline = ContinuousClock.now + timeout
        repeat {
            if FileManager.default.fileExists(atPath: resultURL.path) {
                let data = try Data(contentsOf: resultURL)
                try data.write(to: retainedResult, options: .atomic)
                NSLog("Captured Guest lock/input diagnostics at %@", retainedResult.path)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw ProbeError.timeout
    }

    static func runObservedLockCycle(
        client: VMOmarchyGuestAgentClient,
        sharedDirectory: URL,
        sendLockShortcut: () -> Bool,
        sendUnlockSecret: () -> Bool
    ) async throws -> LockCycle {
        let nonce = UUID().uuidString.lowercased()
        let probeDirectory = sharedDirectory.appending(path: ".ezvm-lock-cycle-\(nonce)")
        let guestDirectory = "/mnt/ezvm-shared/\(probeDirectory.lastPathComponent)"
        var completed = false
        defer {
            if completed {
                try? FileManager.default.removeItem(at: probeDirectory)
            } else {
                NSLog("Retained failed Guest lock probe at %@", probeDirectory.path)
            }
        }
        try FileManager.default.createDirectory(
            at: probeDirectory,
            withIntermediateDirectories: false
        )
        try Data(lockWatcherScript(guestDirectory: guestDirectory).utf8).write(
            to: probeDirectory.appending(path: "watch-lock.sh"),
            options: .atomic
        )

        try await client.injectKeyChord(modifiers: [125], key: 28)
        try await Task.sleep(for: .seconds(2))
        try await client.typeUSASCII("bash \(guestDirectory)/watch-lock.sh\n")
        try await waitForFile(probeDirectory.appending(path: "ready"))

        guard sendLockShortcut() else { throw ProbeError.shortcutUnavailable }
        try await waitForFile(probeDirectory.appending(path: "locked"))
        let lockedAt = Date()
        // Keep the Omarchy lock screen alive for at least one authenticated Agent heartbeat.
        // This proves the product status channel observes the locked state in
        // addition to the Guest-side process watcher proving the UI transition.
        try await Task.sleep(for: .seconds(11))
        guard sendUnlockSecret() else { throw ProbeError.shortcutUnavailable }
        try await waitForFile(probeDirectory.appending(path: "unlocked"))
        // Lock state APIs can briefly or incorrectly report false after a
        // rejected password. Prove that a normal desktop shortcut and command
        // can actually execute before accepting the cycle as recovered.
        try await verifyInteractiveDesktop(
            client: client,
            sharedDirectory: sharedDirectory
        )
        let unlockedAt = Date()
        completed = true
        return LockCycle(lockedAt: lockedAt, unlockedAt: unlockedAt)
    }

    static func sendDesktopNotification(
        client: VMOmarchyGuestAgentClient,
        sharedDirectory: URL,
        title: String
    ) async throws {
        let nonce = UUID().uuidString.lowercased()
        let stem = ".ezvm-notification-\(nonce)"
        let scriptURL = sharedDirectory.appending(path: "\(stem).sh")
        let resultURL = sharedDirectory.appending(path: "\(stem).done")
        let guestScript = "/mnt/ezvm-shared/\(scriptURL.lastPathComponent)"
        let guestResult = "/mnt/ezvm-shared/\(resultURL.lastPathComponent)"
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: resultURL)
        }
        let script = """
        #!/bin/bash
        set -euo pipefail
        notify-send --app-name='EZVM Omarchy Acceptance' --urgency=normal \
          '\(title)' 'Guest to macOS notification bridge'
        touch '\(guestResult)'
        """
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try await client.injectKeyChord(modifiers: [125], key: 28)
        try await Task.sleep(for: .seconds(2))
        try await client.typeUSASCII("bash \(guestScript)\n")
        try await waitForFile(resultURL)
    }

    static func verifyInteractiveDesktop(
        client: VMOmarchyGuestAgentClient,
        sharedDirectory: URL,
        timeout: Duration = .seconds(8)
    ) async throws {
        let nonce = UUID().uuidString.lowercased()
        let stem = ".ezvm-interactive-\(nonce)"
        let scriptURL = sharedDirectory.appending(path: "\(stem).sh")
        let resultURL = sharedDirectory.appending(path: "\(stem).done")
        let guestScript = "/mnt/ezvm-shared/\(scriptURL.lastPathComponent)"
        let guestResult = "/mnt/ezvm-shared/\(resultURL.lastPathComponent)"
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: resultURL)
        }
        try Data("#!/bin/bash\nset -euo pipefail\ntouch '\(guestResult)'\n".utf8)
            .write(to: scriptURL, options: .atomic)
        try await client.injectKeyChord(modifiers: [125], key: 28)
        try await Task.sleep(for: .seconds(2))
        try await client.typeUSASCII("bash \(guestScript)\n")
        try await waitForFile(resultURL, timeout: timeout)
    }

    private static func waitForFile(
        _ url: URL,
        timeout requestedTimeout: Duration = .seconds(20)
    ) async throws {
        let deadline = ContinuousClock.now + requestedTimeout
        repeat {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw ProbeError.timeout
    }

    nonisolated static func probeScript(resultPath: String) -> String {
        """
        #!/bin/bash
        set +e
        result='\(resultPath)'
        partial="$result.part"
        rm -f -- "$partial" "$result"
        {
          printf '%s\n' '=== hyprctl version ==='
          hyprctl version
          printf '%s\n' '=== hyprctl binds -j ==='
          hyprctl binds -j
          printf '%s\n' '=== hyprctl devices -j ==='
          hyprctl devices -j
          printf '%s\n' '=== hyprctl activewindow -j ==='
          hyprctl activewindow -j
          printf '%s\n' '=== omarchy shell ==='
          command -v omarchy-shell || true
          OMARCHY_SHELL_IPC_TIMEOUT=0.5s omarchy-shell lock status || true
          pgrep -a omarchy-shell || true
        } > "$partial" 2>&1
        mv -f -- "$partial" "$result"
        """
    }

    nonisolated static func lockWatcherScript(guestDirectory: String) -> String {
        """
        #!/bin/bash
        set +e
        d='\(guestDirectory)'
        command -v omarchy-shell > "$d/omarchy-shell-command.txt" 2>&1 || exit 1
        lock_state() {
          OMARCHY_SHELL_IPC_TIMEOUT=0.5s omarchy-shell lock isLocked 2> "$d/lock-query-error.txt"
        }
        for _ in $(seq 1 400); do
          state=$(lock_state)
          printf '%s\n' "$state" > "$d/lock-state.txt"
          if [[ $state == true || $state == false ]]; then touch "$d/ready"; break; fi
          sleep 0.05
        done
        [[ -e "$d/ready" ]] || exit 1
        while [[ $(lock_state) != true ]]; do sleep 0.05; done
        touch "$d/locked"
        while [[ $(lock_state) != false ]]; do sleep 0.05; done
        touch "$d/unlocked"
        """
    }
}
