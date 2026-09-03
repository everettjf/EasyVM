import SwiftUI
import EZVMCore

@main
struct EZVMOmarchyApp: App {
    private let workspaceManager: VMOmarchyWorkspaceManager

    init() {
        do {
            workspaceManager = VMOmarchyWorkspaceManager(layout: try .userDomain())
        } catch {
            let fallback = FileManager.default.temporaryDirectory
                .appending(path: "EZVM Omarchy Unavailable", directoryHint: .isDirectory)
            workspaceManager = VMOmarchyWorkspaceManager(
                layout: .init(applicationSupportRoot: fallback)
            )
        }
    }

    var body: some Scene {
        WindowGroup("EZVM Omarchy") {
            OmarchyRootView(profile: .production, workspaceManager: workspaceManager)
                .frame(minWidth: 820, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.contentMinSize)
    }
}

struct OmarchyRootView: View {
    let profile: VMOmarchyProfile
    let workspaceManager: VMOmarchyWorkspaceManager

    var body: some View {
        switch workspaceManager.inspect() {
        case .notPrepared:
            OmarchyWelcomeView(profile: profile)
        case .ready:
            OmarchyVirtualMachineView(layout: workspaceManager.layout, profile: profile)
        case .recovering(let reason):
            ContentUnavailableView(
                "Omarchy needs recovery",
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text(reason)
            )
        }
    }
}

private struct OmarchyWelcomeView: View {
    let profile: VMOmarchyProfile

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 58))
                .foregroundStyle(.tint)
            Text("Welcome to EZVM Omarchy")
                .font(.largeTitle.weight(.semibold))
            Text("One Omarchy workspace, deeply integrated with macOS.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Divider().frame(maxWidth: 420)
            Text("Factory image download and first-owner setup are required before this workspace can start.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            LabeledContent("Planned disk capacity", value: ByteCountFormatter.string(fromByteCount: Int64(profile.diskCapacityBytes), countStyle: .file))
                .frame(maxWidth: 420)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
