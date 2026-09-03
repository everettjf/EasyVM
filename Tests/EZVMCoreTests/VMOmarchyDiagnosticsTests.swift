import Virtualization
import XCTest
@testable import EZVMCore

final class VMOmarchyDiagnosticsTests: XCTestCase {
    func testReportContainsOperationalEvidenceWithoutPathsTokensOrFileNames() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root.appending(path: "private-user-name"))
        let factory = root.appending(path: "factory.asif")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: factory)
        let secret = "super-secret-enrollment-token"
        let metadata = VMOmarchyWorkspaceMetadata(
            productID: VMOmarchyProfile.production.productID,
            createdAt: Date(timeIntervalSince1970: 1),
            factoryImageVersion: "factory-1",
            omarchyRevision: "omarchy-2",
            guestAgentVersion: "agent-3",
            guestCapabilities: ["shutdown-v1", "clipboard-text-v1"]
        )
        try VMOmarchyWorkspaceManager(layout: layout).prepare(
            factoryDisk: factory,
            configuration: try JSONEncoder().encode(metadata),
            machineIdentifier: VZGenericMachineIdentifier().dataRepresentation
        )
        try Data("contents".utf8).write(to: layout.shared.appending(path: "customer-project.txt"))
        try Data(secret.utf8).write(to: layout.enrollment.appending(path: "extra-secret"))
        let status = VMOmarchyGuestStatus(
            agentVersion: "agent-3",
            omarchyRevision: "omarchy-2",
            hostName: "guest-host",
            addresses: ["192.0.2.1"],
            capabilities: Set(VMOmarchyProfile.production.requiredGuestCapabilities),
            desktopSessionActive: true,
            provisioningPending: false
        )

        let report = VMOmarchyDiagnostics().report(
            layout: layout,
            appVersion: "0.1.0",
            integrationState: .ready(status),
            generatedAt: Date(timeIntervalSince1970: 2)
        )
        let encoded = try XCTUnwrap(String(data: report.encoded(), encoding: .utf8))

        XCTAssertEqual(report.workspaceState, "ready")
        XCTAssertEqual(report.liveIntegrationState, "ready")
        XCTAssertEqual(report.factoryImageVersion, "factory-1")
        XCTAssertEqual(report.storage.sharedRegularFileCount, 1)
        XCTAssertEqual(report.storage.sharedRegularFileBytes, 8)
        XCTAssertFalse(encoded.contains(root.path))
        XCTAssertFalse(encoded.contains("private-user-name"))
        XCTAssertFalse(encoded.contains("customer-project.txt"))
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains("guest-host"))
        XCTAssertFalse(encoded.contains("192.0.2.1"))
    }

    func testBrokenWorkspaceReportUsesStableReasonCategory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        try FileManager.default.createDirectory(at: layout.workspace, withIntermediateDirectories: true)

        let report = VMOmarchyDiagnostics().report(
            layout: layout,
            appVersion: String(repeating: "a", count: 200),
            integrationState: .disconnected("sensitive local error")
        )

        XCTAssertEqual(report.workspaceState, "recovery-required")
        XCTAssertEqual(report.liveIntegrationState, "disconnected")
        XCTAssertLessThanOrEqual(report.appVersion.utf8.count, 128)
    }
}
