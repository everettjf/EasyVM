import SwiftUI
import AppKit
import EZVMCore
import Virtualization

@main
struct EZVMOmarchyApp: App {
    @NSApplicationDelegateAdaptor(OmarchyApplicationDelegate.self) private var applicationDelegate
    private let workspaceManager: VMOmarchyWorkspaceManager

    init() {
        do {
            workspaceManager = VMOmarchyWorkspaceManager(
                layout: try OmarchyWorkspaceConfiguration.layout()
            )
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
                .onAppear {
                    OmarchyReleaseReadinessReporter.reportWhenReady(
                        workspaceManager: workspaceManager
                    )
                }
        }
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.contentMinSize)
    }
}

enum OmarchyWorkspaceConfiguration {
    static let acceptanceEnabledKey = "EZVM_OMARCHY_ACCEPTANCE"
    static let acceptanceRootKey = "EZVM_OMARCHY_ACCEPTANCE_WORKSPACE_ROOT"
    static let acceptanceUnlockPasswordKey = "EZVM_OMARCHY_ACCEPTANCE_UNLOCK_PASSWORD"

    static func acceptanceOwnerProvisioningPassword(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        guard environment[acceptanceEnabledKey] == "1",
              (try? layout(environment: environment, fileManager: fileManager)) != nil,
              let password = environment[acceptanceUnlockPasswordKey],
              !password.isEmpty else { return nil }
        return password
    }

    static func layout(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> VMOmarchyWorkspaceLayout {
        guard environment[acceptanceEnabledKey] == "1" else {
            return try .userDomain(fileManager: fileManager)
        }
        guard let path = environment[acceptanceRootKey], path.hasPrefix("/") else {
            throw ConfigurationError.invalidAcceptanceRoot
        }
        let root = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard VMOmarchyTemporaryPathPolicy.contains(root, fileManager: fileManager) else {
            throw ConfigurationError.invalidAcceptanceRoot
        }
        return .init(applicationSupportRoot: root)
    }

    enum ConfigurationError: Error {
        case invalidAcceptanceRoot
    }
}

struct OmarchyRootView: View {
    let profile: VMOmarchyProfile
    let workspaceManager: VMOmarchyWorkspaceManager
    @State private var workspaceRevision = UUID()
    @State private var recoveryError: String?
    @State private var showsRecoveryConfirmation = false
    @State private var isMigrating = false

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
        case .migrationRequired(let fromVersion):
            VStack(spacing: 18) {
                ContentUnavailableView(
                    "Omarchy workspace update required",
                    systemImage: "externaldrive.badge.timemachine",
                    description: Text("Workspace format \(fromVersion) must be migrated before Omarchy can start.")
                )
                if let recoveryError {
                    Text(recoveryError).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                if isMigrating {
                    ProgressView("Creating protected backup and migrating…")
                } else {
                    Button("Create Backup and Migrate", systemImage: "arrow.triangle.2.circlepath") {
                        migrateWorkspace()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(40)
        case .recovering(let reason):
            VStack(spacing: 18) {
                ContentUnavailableView(
                    "Omarchy needs recovery",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(reason)
                )
                if let recoveryError {
                    Text(recoveryError).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                HStack {
                    Button("Repair and Recheck", systemImage: "wrench.and.screwdriver") {
                        repairInterruptedRecovery()
                    }
                    Button("Reveal Data", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([workspaceManager.layout.workspace])
                    }
                    Button("Preserve and Reinstall…", systemImage: "arrow.counterclockwise") {
                        showsRecoveryConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(40)
            .confirmationDialog(
                "Preserve the broken workspace and reinstall Omarchy?",
                isPresented: $showsRecoveryConfirmation,
                titleVisibility: .visible
            ) {
                Button("Preserve and Reinstall") { preserveAndReinstall() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The existing workspace will be moved into the Recovery folder. It will not be deleted.")
            }
        }
    }

    private func preserveAndReinstall() {
        do {
            _ = try workspaceManager.quarantineBrokenWorkspace()
            recoveryError = nil
            workspaceRevision = UUID()
        } catch {
            recoveryError = error.localizedDescription
        }
    }

    private func repairInterruptedRecovery() {
        do {
            try VMOmarchyRecoveryManager(workspaceManager: workspaceManager).recoverInterruptedOperations()
            recoveryError = nil
            workspaceRevision = UUID()
        } catch {
            recoveryError = error.localizedDescription
        }
    }

    private func migrateWorkspace() {
        guard !isMigrating else { return }
        isMigrating = true
        let manager = workspaceManager
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try manager.migrateWorkspace() }
            DispatchQueue.main.async {
                isMigrating = false
                switch result {
                case .success:
                    recoveryError = nil
                    workspaceRevision = UUID()
                case .failure(let error):
                    recoveryError = error.localizedDescription
                }
            }
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
                let metadata = try JSONEncoder().encode(VMOmarchyWorkspaceMetadata(
                    productID: profile.productID,
                    createdAt: Date(),
                    factoryImageVersion: factory.manifest.payload.imageVersion,
                    omarchyRevision: factory.manifest.payload.omarchyRevision,
                    guestAgentVersion: factory.manifest.payload.guestAgentVersion,
                    guestCapabilities: factory.manifest.payload.guestCapabilities.sorted()
                ))
                try workspaceManager.prepare(
                    factoryDisk: factory.diskURL,
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

enum FactoryTrustConfiguration {
    static func publicKey(bundle: Bundle = .main) -> Data? {
        guard let encoded = bundle.object(forInfoDictionaryKey: "EZVMOmarchyFactoryPublicKeyBase64") as? String,
              !encoded.isEmpty,
              let data = Data(base64Encoded: encoded),
              data.count == 32 else { return nil }
        return data
    }
}
