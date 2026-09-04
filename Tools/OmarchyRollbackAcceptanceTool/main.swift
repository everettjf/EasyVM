import CryptoKit
import EZVMCore
import Foundation

private struct RollbackObservation: Codable {
    let schemaVersion: Int
    let observedAt: Date
    let sourceRevision: String
    let snapshotID: String
    let snapshotName: String
    let snapshotProtected: Bool
    let beforeSHA256: String
    let simulatedUpdateSHA256: String
    let restoredSHA256: String
    let restoredMatchesSnapshot: Bool
    let workspaceReadyAfterRestore: Bool
}

@main
enum OmarchyRollbackAcceptanceTool {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3 else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let root = URL(filePath: arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        guard VMOmarchyTemporaryPathPolicy.contains(root) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let revision = arguments[1]
        guard revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let output = URL(filePath: arguments[2]).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw CocoaError(.fileWriteFileExists)
        }

        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        let workspaceManager = VMOmarchyWorkspaceManager(layout: layout)
        guard workspaceManager.inspect() == .ready else { throw CocoaError(.fileReadCorruptFile) }
        let marker = layout.workspace.appending(path: ".ezvm-update-rollback-acceptance")
        guard !FileManager.default.fileExists(atPath: marker.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let nonce = UUID().uuidString.lowercased()
        let before = Data("before-update:\(nonce)".utf8)
        let after = Data("after-update:\(nonce)".utf8)
        defer { try? FileManager.default.removeItem(at: marker) }
        try before.write(to: marker, options: [.atomic])

        let recovery = VMOmarchyRecoveryManager(workspaceManager: workspaceManager)
        let point = try recovery.createProtectedPreUpdatePoint(
            targetVersion: "acceptance-\(nonce.prefix(8))"
        )
        try after.write(to: marker, options: [.atomic])
        try recovery.restore(id: point.id)
        let restored = try Data(contentsOf: marker)
        let observation = RollbackObservation(
            schemaVersion: 1,
            observedAt: Date(),
            sourceRevision: revision,
            snapshotID: point.id,
            snapshotName: point.name,
            snapshotProtected: point.isProtected,
            beforeSHA256: digest(before),
            simulatedUpdateSHA256: digest(after),
            restoredSHA256: digest(restored),
            restoredMatchesSnapshot: restored == before && restored != after,
            workspaceReadyAfterRestore: workspaceManager.inspect() == .ready
        )
        guard observation.snapshotProtected, observation.restoredMatchesSnapshot,
              observation.workspaceReadyAfterRestore else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(observation).write(to: output, options: [.atomic])
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
