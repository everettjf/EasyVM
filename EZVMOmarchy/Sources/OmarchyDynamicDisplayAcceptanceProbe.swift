import EZVMCore
import Foundation
import Virtualization

struct OmarchyDisplaySize: Codable, Equatable {
    let width: Int
    let height: Int
}

struct OmarchyDynamicDisplayRoundTrip: Codable, Equatable {
    let observedAt: Date
    let guestBefore: OmarchyDisplaySize
    let guestAfter: OmarchyDisplaySize
    let hostViewAfter: OmarchyDisplaySize
}

enum OmarchyDynamicDisplayProbeState: Equatable {
    case notRun
    case running
    case passed(OmarchyDynamicDisplayRoundTrip)
    case failed(String)
}

@MainActor
enum OmarchyDynamicDisplayAcceptanceProbe {
    private static let timeout: Duration = .seconds(20)

    static func run(
        client: VMOmarchyGuestAgentClient,
        view: VZVirtualMachineView,
        sharedDirectory: URL
    ) async throws -> OmarchyDynamicDisplayRoundTrip {
        guard let window = view.window else { throw ProbeError.missingWindow }
        let nonce = UUID().uuidString.lowercased()
        let probeDirectory = sharedDirectory.appending(path: ".ezvm-display-\(nonce)")
        let guestDirectory = "/mnt/ezvm-shared/\(probeDirectory.lastPathComponent)"
        let originalContentSize = window.contentLayoutRect.size
        defer {
            window.setContentSize(originalContentSize)
            try? FileManager.default.removeItem(at: probeDirectory)
        }
        try FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: false)
        try Data(script(guestDirectory: guestDirectory).utf8)
            .write(to: probeDirectory.appending(path: "probe.sh"))

        try await client.typeUSASCII("bash \(guestDirectory)/probe.sh\n")
        let before = try await waitForDisplay(at: probeDirectory.appending(path: "before.json"))

        let targetWidth: CGFloat = originalContentSize.width > 980 ? 880 : 1100
        let targetHeight: CGFloat = originalContentSize.height > 700 ? 640 : 760
        window.setContentSize(NSSize(width: targetWidth, height: targetHeight))
        try await Task.sleep(for: .milliseconds(500))
        // Hyprland reports the virtual display's backing pixels, while AppKit
        // bounds are expressed in logical points on Retina displays.
        let viewSize = view.convertToBacking(view.bounds).size
        let hostAfter = OmarchyDisplaySize(
            width: Int(viewSize.width.rounded()),
            height: Int(viewSize.height.rounded())
        )
        try Data().write(to: probeDirectory.appending(path: "resize-go"), options: .atomic)
        let after = try await waitForDisplay(at: probeDirectory.appending(path: "after.json"))
        guard before != after else { throw ProbeError.resolutionUnchanged(before) }
        guard abs(after.width - hostAfter.width) <= 4,
              abs(after.height - hostAfter.height) <= 4 else {
            throw ProbeError.hostGuestMismatch(host: hostAfter, guest: after)
        }
        return OmarchyDynamicDisplayRoundTrip(
            observedAt: Date(),
            guestBefore: before,
            guestAfter: after,
            hostViewAfter: hostAfter
        )
    }

    private static func script(guestDirectory: String) -> String {
        """
        #!/usr/bin/env bash
        set -eu
        d='\(guestDirectory)'
        hyprctl monitors -j > "$d/before.json"
        while [ ! -f "$d/resize-go" ]; do sleep 0.1; done
        sleep 3
        hyprctl monitors -j > "$d/after.json"
        """
    }

    private static func waitForDisplay(at url: URL) async throws -> OmarchyDisplaySize {
        let deadline = ContinuousClock.now + timeout
        repeat {
            if let data = try? Data(contentsOf: url), !data.isEmpty,
               let size = try? decodeDisplay(data) { return size }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw ProbeError.timeout(url.lastPathComponent)
    }

    static func decodeDisplay(_ data: Data) throws -> OmarchyDisplaySize {
        guard let monitors = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let monitor = monitors.first(where: { ($0["disabled"] as? Bool) != true }),
              let width = monitor["width"] as? Int,
              let height = monitor["height"] as? Int,
              width > 0, height > 0 else { throw ProbeError.invalidMonitorJSON }
        return OmarchyDisplaySize(width: width, height: height)
    }

    enum ProbeError: LocalizedError {
        case hostGuestMismatch(host: OmarchyDisplaySize, guest: OmarchyDisplaySize)
        case invalidMonitorJSON
        case missingWindow
        case resolutionUnchanged(OmarchyDisplaySize)
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .hostGuestMismatch(let host, let guest):
                "Guest display \(guest.width)x\(guest.height) does not match Host view \(host.width)x\(host.height)."
            case .invalidMonitorJSON: "Hyprland returned invalid monitor JSON."
            case .missingWindow: "The Omarchy display has no Host window."
            case .resolutionUnchanged(let size):
                "Guest display remained \(size.width)x\(size.height) after Host resize."
            case .timeout(let file): "Timed out waiting for Guest display evidence \(file)."
            }
        }
    }
}
