import SwiftUI
import EZVMCore

@main
struct EZVMOmarchyApp: App {
    var body: some Scene {
        WindowGroup("EZVM Omarchy") {
            OmarchyRootView(profile: .production)
                .frame(minWidth: 820, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.contentMinSize)
    }
}

struct OmarchyRootView: View {
    let profile: VMOmarchyProfile

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 58))
                .foregroundStyle(.tint)
            Text("EZVM Omarchy")
                .font(.largeTitle.weight(.semibold))
            Text("One Omarchy workspace, deeply integrated with macOS.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Divider()
                .frame(maxWidth: 420)
            LabeledContent("Product", value: profile.productID)
            LabeledContent("Required guest features", value: "\(profile.requiredGuestCapabilities.count)")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
