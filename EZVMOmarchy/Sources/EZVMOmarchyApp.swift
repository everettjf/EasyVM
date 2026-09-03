import SwiftUI
import EZVMCore
import Virtualization

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
    @State private var workspaceRevision = UUID()

    var body: some View {
        switch workspaceManager.inspect() {
        case .notPrepared:
            OmarchyWelcomeView(
                profile: profile,
                workspaceManager: workspaceManager,
                workspacePrepared: { workspaceRevision = UUID() }
            )
            .id(workspaceRevision)
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
    let workspaceManager: VMOmarchyWorkspaceManager
    let workspacePrepared: () -> Void
    @State private var installState: InstallState = .idle

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
            installControls
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var installControls: some View {
        switch installState {
        case .idle:
            Button("Prepare Omarchy") { prepare() }
                .buttonStyle(.borderedProminent)
        case .checkingSpace:
            ProgressView("Checking available storage…")
        case .downloading(let fraction):
            VStack(spacing: 8) {
                ProgressView(value: fraction)
                    .frame(maxWidth: 360)
                Text("Downloading and verifying Omarchy… \(Int(fraction * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .creatingWorkspace:
            ProgressView("Creating your Omarchy workspace…")
        case .failed(let message):
            VStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { prepare() }
            }
            .frame(maxWidth: 520)
        }
    }

    private func prepare() {
        installState = .checkingSpace
        Task {
            do {
                let forecast = try VMOmarchyStorageForecast.inspect(
                    volumeContaining: workspaceManager.layout.applicationSupportRoot.deletingLastPathComponent(),
                    downloadBytes: profile.factoryImage.maximumDownloadBytes,
                    workspaceBytes: profile.factoryImage.maximumDownloadBytes
                )
                guard forecast.hasEnoughSpace else {
                    throw OnboardingError.insufficientSpace(required: forecast.requiredBytes, available: forecast.availableBytes)
                }
                guard let publicKey = FactoryTrustConfiguration.publicKey() else {
                    throw OnboardingError.releaseChannelNotConfigured
                }
                let installer = VMOmarchyFactoryInstaller(
                    profile: profile,
                    cacheDirectory: workspaceManager.layout.cache,
                    publicKey: publicKey,
                    transport: VMOmarchyURLSessionTransport()
                )
                let factory = try await installer.install { received, expected in
                    let denominator = max(expected, 1)
                    let fraction = min(max(Double(received) / Double(denominator), 0), 1)
                    Task { @MainActor in installState = .downloading(fraction) }
                }
                installState = .creatingWorkspace
                let identifier = VZGenericMachineIdentifier().dataRepresentation
                let metadata = try JSONEncoder().encode(WorkspaceMetadata(
                    schemaVersion: 1,
                    productID: profile.productID,
                    createdAt: Date()
                ))
                try workspaceManager.prepare(
                    factoryDisk: factory,
                    configuration: metadata,
                    machineIdentifier: identifier
                )
                workspacePrepared()
            } catch {
                installState = .failed(error.localizedDescription)
            }
        }
    }

    private enum InstallState: Equatable {
        case idle
        case checkingSpace
        case downloading(Double)
        case creatingWorkspace
        case failed(String)
    }

    private struct WorkspaceMetadata: Codable {
        let schemaVersion: Int
        let productID: String
        let createdAt: Date
    }

    private enum OnboardingError: LocalizedError {
        case releaseChannelNotConfigured
        case insufficientSpace(required: UInt64, available: UInt64)

        var errorDescription: String? {
            switch self {
            case .releaseChannelNotConfigured:
                "This build has no trusted Omarchy factory signing key. Install an official build or configure the development release channel."
            case .insufficientSpace(let required, let available):
                "Omarchy needs \(Self.bytes(required)) free; this volume currently has \(Self.bytes(available))."
            }
        }

        private static func bytes(_ value: UInt64) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
        }
    }
}

private enum FactoryTrustConfiguration {
    static func publicKey(bundle: Bundle = .main) -> Data? {
        guard let encoded = bundle.object(forInfoDictionaryKey: "EZVMOmarchyFactoryPublicKeyBase64") as? String,
              !encoded.isEmpty,
              let data = Data(base64Encoded: encoded),
              data.count == 32 else { return nil }
        return data
    }
}
