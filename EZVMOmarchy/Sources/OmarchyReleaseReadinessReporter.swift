import AppKit
import EZVMCore
import Foundation

enum OmarchyReleaseReadinessReporter {
    private static var hasScheduledReport = false

    static func reportWhenReady(
        workspaceManager: VMOmarchyWorkspaceManager,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard !hasScheduledReport,
              let path = environment["EZVM_OMARCHY_GUI_READY_FILE"],
              !path.isEmpty else { return }
        hasScheduledReport = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            report(to: URL(fileURLWithPath: path), workspaceManager: workspaceManager)
        }
    }

    private static func report(
        to destination: URL,
        workspaceManager: VMOmarchyWorkspaceManager
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let window = NSApp.windows.first(where: { $0.isVisible && !$0.isMiniaturized }) else {
            hasScheduledReport = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                report(to: destination, workspaceManager: workspaceManager)
            }
            return
        }
        let workspaceState: String
        switch workspaceManager.inspect() {
        case .notPrepared: workspaceState = "notPrepared"
        case .ready: workspaceState = "ready"
        case .migrationRequired(let version): workspaceState = "migrationRequired:\(version)"
        case .recovering(let reason): workspaceState = "recovering:\(reason)"
        }
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "eventLoopResponsive": true,
            "windowVisible": true,
            "windowWidth": window.frame.width,
            "windowHeight": window.frame.height,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "workspaceRoot": workspaceManager.layout.applicationSupportRoot.path,
            "workspaceState": workspaceState,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: destination, options: .atomic)
        } catch {
            NSLog("Could not write EZVM Omarchy GUI readiness: %@", error.localizedDescription)
        }
    }
}
