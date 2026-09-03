import Foundation

public struct VMOmarchyDiagnosticReport: Codable, Equatable, Sendable {
    public struct Storage: Codable, Equatable, Sendable {
        public let diskLogicalBytes: UInt64?
        public let diskAllocatedBytes: UInt64?
        public let sharedRegularFileCount: Int
        public let sharedRegularFileBytes: UInt64
        public let recoveryPointCount: Int
        public let protectedRecoveryPointCount: Int
    }

    public let schemaVersion: Int
    public let generatedAt: Date
    public let productID: String
    public let appVersion: String
    public let hostOperatingSystem: String
    public let hostArchitecture: String
    public let workspaceState: String
    public let factoryImageVersion: String?
    public let omarchyRevision: String?
    public let guestAgentVersion: String?
    public let guestCapabilities: [String]
    public let liveIntegrationState: String
    public let storage: Storage

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct VMOmarchyDiagnostics {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func report(
        layout: VMOmarchyWorkspaceLayout,
        appVersion: String,
        integrationState: VMOmarchyIntegrationState,
        generatedAt: Date = Date(),
        processInfo: ProcessInfo = .processInfo
    ) -> VMOmarchyDiagnosticReport {
        let manager = VMOmarchyWorkspaceManager(layout: layout, fileManager: fileManager)
        let state = manager.inspect()
        let metadata = try? manager.metadata()
        let recoveryPoints = VMOmarchyRecoveryManager(workspaceManager: manager).recoveryPoints()
        let diskSizes = regularFileSizes(layout.disk)
        let shared = sharedFileSummary(layout.shared)
        return VMOmarchyDiagnosticReport(
            schemaVersion: 1,
            generatedAt: generatedAt,
            productID: VMOmarchyProfile.production.productID,
            appVersion: bounded(appVersion, maximumUTF8Bytes: 128),
            hostOperatingSystem: bounded(processInfo.operatingSystemVersionString, maximumUTF8Bytes: 256),
            hostArchitecture: bounded(
                processInfo.environment["PROCESSOR_ARCHITECTURE"] ?? "arm64",
                maximumUTF8Bytes: 32
            ),
            workspaceState: workspaceStateDescription(state),
            factoryImageVersion: metadata?.factoryImageVersion,
            omarchyRevision: metadata?.omarchyRevision,
            guestAgentVersion: metadata?.guestAgentVersion,
            guestCapabilities: metadata?.guestCapabilities?.sorted() ?? [],
            liveIntegrationState: integrationDescription(integrationState),
            storage: .init(
                diskLogicalBytes: diskSizes.logical,
                diskAllocatedBytes: diskSizes.allocated,
                sharedRegularFileCount: shared.count,
                sharedRegularFileBytes: shared.bytes,
                recoveryPointCount: recoveryPoints.count,
                protectedRecoveryPointCount: recoveryPoints.filter(\.isProtected).count
            )
        )
    }

    private func workspaceStateDescription(_ state: VMOmarchyWorkspaceState) -> String {
        switch state {
        case .notPrepared: "not-prepared"
        case .migrationRequired(let version): "migration-required-from-\(version)"
        case .ready: "ready"
        case .recovering: "recovery-required"
        }
    }

    private func integrationDescription(_ state: VMOmarchyIntegrationState) -> String {
        switch state {
        case .connecting: "connecting"
        case .authenticating: "authenticating"
        case .disconnected: "disconnected"
        case .ready(let status):
            VMOmarchyIntegrationAssessment.evaluate(
                status: status,
                requiredCapabilities: VMOmarchyProfile.production.requiredGuestCapabilities
            ).isReady ? "ready" : "degraded"
        }
    }

    private func regularFileSizes(_ url: URL) -> (logical: UInt64?, allocated: UInt64?) {
        guard !isSymbolicLink(url),
              let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .fileAllocatedSizeKey,
              ]), values.isRegularFile == true else { return (nil, nil) }
        return (
            values.fileSize.map { UInt64(max(0, $0)) },
            values.fileAllocatedSize.map { UInt64(max(0, $0)) }
        )
    }

    private func sharedFileSummary(_ root: URL) -> (count: Int, bytes: UInt64) {
        guard !isSymbolicLink(root),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return (0, 0) }
        var count = 0
        var bytes: UInt64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ]) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            count += 1
            let (sum, overflow) = bytes.addingReportingOverflow(UInt64(max(0, values.fileSize ?? 0)))
            bytes = overflow ? UInt64.max : sum
        }
        return (count, bytes)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func bounded(_ value: String, maximumUTF8Bytes: Int) -> String {
        var result = value
        while result.utf8.count > maximumUTF8Bytes { result.removeLast() }
        return result
    }
}
