import Foundation
import XCTest
@testable import EZVMCore

final class VMSnapshotManagerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZVMTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testCreateListRenameRestoreAndDeleteSnapshot() throws {
        try write("original config", to: "config.json")
        try write("original disk", to: "Disk.img")
        try FileManager.default.createDirectory(
            at: temporaryRoot.appendingPathComponent("Nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write("nested state", to: "Nested/state.txt")
        try write("ignored", to: ".DS_Store")

        let snapshot = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Before change")
        )

        XCTAssertEqual(VMSnapshotManager.snapshotCount(vmRootPath: temporaryRoot), 1)
        XCTAssertEqual(VMSnapshotManager.listSnapshots(vmRootPath: temporaryRoot).first?.name, "Before change")
        XCTAssertEqual(snapshot.backend, .apfsClone)
        XCTAssertTrue(snapshot.diskLayers.isEmpty)
        XCTAssertGreaterThan(snapshot.totalSize ?? 0, 0)
        XCTAssertFalse(snapshot.fileManifest?.isEmpty ?? true)
        XCTAssertTrue(VMSnapshotManager.auditSnapshot(vmRootPath: temporaryRoot, snapshot: snapshot).isValid)

        try write("changed config", to: "config.json")
        try FileManager.default.removeItem(at: temporaryRoot.appendingPathComponent("Disk.img"))
        try write("new file", to: "new.txt")

        try unwrapSuccess(
            VMSnapshotManager.restoreSnapshot(vmRootPath: temporaryRoot, snapshot: snapshot)
        )

        XCTAssertEqual(try read("config.json"), "original config")
        XCTAssertEqual(try read("Disk.img"), "original disk")
        XCTAssertEqual(try read("Nested/state.txt"), "nested state")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRoot.appendingPathComponent("new.txt").path))
        XCTAssertEqual(try read(".DS_Store"), "ignored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRoot.appendingPathComponent(".restore-staging").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRoot.appendingPathComponent(".restore-backup").path))

        try unwrapSuccess(
            VMSnapshotManager.renameSnapshot(vmRootPath: temporaryRoot, snapshot: snapshot, newName: "Renamed")
        )
        XCTAssertEqual(VMSnapshotManager.listSnapshots(vmRootPath: temporaryRoot).first?.name, "Renamed")

        try unwrapSuccess(
            VMSnapshotManager.deleteSnapshot(vmRootPath: temporaryRoot, snapshot: snapshot)
        )
        XCTAssertEqual(VMSnapshotManager.snapshotCount(vmRootPath: temporaryRoot), 0)
    }

    func testAuditAcceptsEquivalentRootURLWithoutDirectoryHint() throws {
        try write("configuration", to: "config.json")
        try write("disk", to: "Disk.img")

        // VMModel URLs can be reconstructed from persisted path strings, which
        // drops Foundation's directory hint and changes only the trailing `/`.
        let persistedRoot = URL(fileURLWithPath: temporaryRoot.path)
        let snapshot = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: persistedRoot, name: "Persisted URL")
        )

        let report = VMSnapshotManager.auditSnapshot(vmRootPath: persistedRoot, snapshot: snapshot)
        XCTAssertTrue(report.isValid, report.errors.joined(separator: "; "))
    }

    func testCreateSnapshotFailsForEmptyMachine() throws {
        switch VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Empty") {
        case .success:
            XCTFail("Expected an empty machine directory to be rejected")
        case .failure(let message):
            XCTAssertTrue(message.contains("No machine files found"))
        }
        XCTAssertEqual(VMSnapshotManager.snapshotCount(vmRootPath: temporaryRoot), 0)
    }

    func testListSnapshotsSkipsCorruptMetadata() throws {
        let corruptDirectory = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
            .appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corruptDirectory.appendingPathComponent("snapshot.json"))

        XCTAssertTrue(VMSnapshotManager.listSnapshots(vmRootPath: temporaryRoot).isEmpty)
    }

    func testListSnapshotsRejectsMetadataWhoseIdentifierDoesNotMatchDirectory() throws {
        try write("disk", to: "Disk.img")
        let snapshot = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Original")
        )
        let metadataURL = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
            .appendingPathComponent(snapshot.id)
            .appendingPathComponent("snapshot.json")
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        object["id"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: object).write(to: metadataURL, options: .atomic)

        XCTAssertTrue(VMSnapshotManager.listSnapshots(vmRootPath: temporaryRoot).isEmpty)
        XCTAssertFalse(VMSnapshotManager.auditSnapshot(vmRootPath: temporaryRoot, snapshot: snapshot).isValid)
    }

    func testAuditDetectsChecksumChangeAndRestoreLeavesMachineUntouched() throws {
        try write("original config", to: "config.json")
        try write("original disk", to: "Disk.img")
        let snapshot = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Protected data")
        )
        let snapshotConfig = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
            .appendingPathComponent(snapshot.id)
            .appendingPathComponent("files/config.json")
        try Data("tampered config".utf8).write(to: snapshotConfig)
        try write("current config", to: "config.json")

        let report = VMSnapshotManager.auditSnapshot(vmRootPath: temporaryRoot, snapshot: snapshot)
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.errors.contains { $0.contains("config.json") })
        if case .success = VMSnapshotManager.restoreSnapshot(vmRootPath: temporaryRoot, snapshot: snapshot) {
            XCTFail("A corrupt snapshot must not be restored")
        }
        XCTAssertEqual(try read("config.json"), "current config")
    }

    func testAuditDetectsTruncatedLargeFileByLogicalSize() throws {
        try Data(repeating: 0x5a, count: 17 * 1024 * 1024).write(
            to: temporaryRoot.appendingPathComponent("Disk.img")
        )
        let snapshot = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Large disk")
        )
        let snapshotDisk = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
            .appendingPathComponent(snapshot.id)
            .appendingPathComponent("files/Disk.img")
        try FileHandle(forWritingTo: snapshotDisk).truncate(atOffset: 1024)

        let report = VMSnapshotManager.auditSnapshot(vmRootPath: temporaryRoot, snapshot: snapshot)
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.errors.contains { $0.contains("size changed") })
    }

    func testSnapshotCreationRejectsSymbolicLinksAndCleansPartialSnapshot() throws {
        try write("disk", to: "Disk.img")
        try FileManager.default.createSymbolicLink(
            at: temporaryRoot.appendingPathComponent("unsafe-link"),
            withDestinationURL: URL(fileURLWithPath: "/tmp")
        )

        if case .success = VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Unsafe") {
            XCTFail("Snapshots containing symbolic links must be rejected")
        }
        XCTAssertTrue(VMSnapshotManager.listSnapshots(vmRootPath: temporaryRoot).isEmpty)
    }

    func testSnapshotsFormBranchesAfterRestore() throws {
        try write("initial", to: "Disk.img")

        let root = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Root")
        )
        XCTAssertNil(root.parentSnapshotID)
        XCTAssertEqual(VMSnapshotManager.currentSnapshotID(vmRootPath: temporaryRoot), root.id)

        try write("first branch", to: "Disk.img")
        let firstBranch = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "First branch")
        )
        XCTAssertEqual(firstBranch.parentSnapshotID, root.id)

        try unwrapSuccess(
            VMSnapshotManager.restoreSnapshot(vmRootPath: temporaryRoot, snapshot: root)
        )
        XCTAssertEqual(VMSnapshotManager.currentSnapshotID(vmRootPath: temporaryRoot), root.id)

        try write("second branch", to: "Disk.img")
        let secondBranch = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Second branch")
        )
        XCTAssertEqual(secondBranch.parentSnapshotID, root.id)

        let tree = VMSnapshotManager.snapshotTree(vmRootPath: temporaryRoot)
        XCTAssertEqual(tree.map(\.id), [root.id])
        XCTAssertEqual(Set(tree[0].children?.map(\.id) ?? []), Set([firstBranch.id, secondBranch.id]))
        XCTAssertEqual(VMSnapshotManager.currentSnapshotID(vmRootPath: temporaryRoot), secondBranch.id)
    }

    func testDeletingTreeRequiresLeavesAndMovesCurrentBranchToParent() throws {
        try write("initial", to: "Disk.img")
        let root = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Root")
        )
        let child = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Child")
        )

        if case let .failure(message) = VMSnapshotManager.deleteSnapshot(vmRootPath: temporaryRoot, snapshot: root) {
            XCTAssertTrue(message.contains("child snapshots"))
        } else {
            XCTFail("Expected a snapshot with children to be protected")
        }

        try unwrapSuccess(
            VMSnapshotManager.deleteSnapshot(vmRootPath: temporaryRoot, snapshot: child)
        )
        XCTAssertEqual(VMSnapshotManager.currentSnapshotID(vmRootPath: temporaryRoot), root.id)

        try unwrapSuccess(
            VMSnapshotManager.deleteSnapshot(vmRootPath: temporaryRoot, snapshot: root)
        )
        XCTAssertNil(VMSnapshotManager.currentSnapshotID(vmRootPath: temporaryRoot))
        XCTAssertTrue(VMSnapshotManager.snapshotTree(vmRootPath: temporaryRoot).isEmpty)
    }

    func testLegacySnapshotMetadataBecomesTreeRoot() throws {
        let snapshotID = UUID().uuidString
        let snapshotDirectory = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
            .appendingPathComponent(snapshotID, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)

        let legacyMetadata: [String: Any] = [
            "id": snapshotID,
            "name": "Legacy",
            "createdAt": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyMetadata)
        try data.write(to: snapshotDirectory.appendingPathComponent("snapshot.json"))

        let snapshots = VMSnapshotManager.listSnapshots(vmRootPath: temporaryRoot)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertNil(snapshots[0].parentSnapshotID)
        XCTAssertEqual(snapshots[0].backend, .apfsClone)
        XCTAssertTrue(snapshots[0].diskLayers.isEmpty)
        XCTAssertEqual(VMSnapshotManager.snapshotTree(vmRootPath: temporaryRoot).first?.id, snapshotID)
    }

    func testRawMachineAlwaysUsesAPFSCloneBackend() throws {
        try write("raw", to: "Disk.img")
        try write(#"{"storageDevices":[{"type":"Block","size":1024,"imagePath":"Disk.img","format":"raw"}]}"#, to: "config.json")

        XCTAssertEqual(VMSnapshotManager.selectedBackend(vmRootPath: temporaryRoot), .apfsClone)
    }

    func testASIFMachineAutomaticallyUsesDiskImageKitLayeredSnapshots() throws {
        let diskURL = temporaryRoot.appendingPathComponent("Disk.asif")
        try unwrapSuccess(VMDiskImageManager.create(format: .asif, at: diskURL, size: 64 * 1024 * 1024))
        try write(
            #"{"storageDevices":[{"type":"Block","size":67108864,"imagePath":"Disk.asif","format":"asif"}]}"#,
            to: "config.json"
        )

        XCTAssertEqual(VMSnapshotManager.selectedBackend(vmRootPath: temporaryRoot), .diskImageKitLayered)
        let image = try VMSnapshotManager.layeredDiskImage(baseURL: diskURL, vmRootPath: temporaryRoot)
        XCTAssertNotNil(image)

        let snapshot = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Layered")
        )
        XCTAssertEqual(snapshot.backend, .diskImageKitLayered)
        XCTAssertEqual(snapshot.diskLayers.count, 1)
        XCTAssertEqual(snapshot.diskLayers[0].baseImageName, "Disk.asif")
        XCTAssertEqual(snapshot.diskLayers[0].layerPaths.count, 1)
        XCTAssertTrue(VMSnapshotManager.auditSnapshot(vmRootPath: temporaryRoot, snapshot: snapshot).isValid)

        try unwrapSuccess(VMSnapshotManager.restoreSnapshot(vmRootPath: temporaryRoot, snapshot: snapshot))
        XCTAssertEqual(VMSnapshotManager.currentSnapshotID(vmRootPath: temporaryRoot), snapshot.id)
    }

    func testInterruptedRestoreRollsBackOriginalBundleAndIsIdempotent() throws {
        try write("partially restored", to: "config.json")
        let backup = temporaryRoot.appendingPathComponent(".restore-backup", isDirectory: true)
        let staging = temporaryRoot.appendingPathComponent(".restore-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("original config".utf8).write(to: backup.appendingPathComponent("config.json"))
        try Data("original disk".utf8).write(to: backup.appendingPathComponent("Disk.img"))
        try Data(#"{"snapshotID":"test","phase":"installing"}"#.utf8)
            .write(to: temporaryRoot.appendingPathComponent(".restore-transaction.json"))

        try unwrapSuccess(VMSnapshotManager.recoverInterruptedRestore(vmRootPath: temporaryRoot))

        XCTAssertEqual(try read("config.json"), "original config")
        XCTAssertEqual(try read("Disk.img"), "original disk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        try unwrapSuccess(VMSnapshotManager.recoverInterruptedRestore(vmRootPath: temporaryRoot))
    }

    func testInterruptedLayeredRestorePreservesBaseAndRollsBackStateAndFiles() throws {
        let base = temporaryRoot.appendingPathComponent("Disk.asif")
        try Data([0x73, 0x68, 0x64, 0x77, 0x01]).write(to: base)
        try write("partially restored", to: "config.json")

        let snapshots = temporaryRoot.appendingPathComponent("Snapshots", isDirectory: true)
        let layers = snapshots.appendingPathComponent("Layers", isDirectory: true)
        let backup = temporaryRoot.appendingPathComponent(".restore-backup", isDirectory: true)
        try FileManager.default.createDirectory(at: layers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let originalConfig = #"{"storageDevices":[{"type":"Block","imagePath":"Disk.asif","format":"asif"}]}"#
        try Data(originalConfig.utf8).write(to: backup.appendingPathComponent("config.json"))
        try Data("new layer".utf8).write(to: layers.appendingPathComponent("new.asif"))
        try Data(#"{"currentSnapshotID":"new","activeDiskLayers":{"Disk.asif":["Snapshots/Layers/new.asif"]}}"#.utf8)
            .write(to: snapshots.appendingPathComponent("state.json"))
        try Data(#"{"snapshotID":"target","phase":"installing","kind":"diskImageKitLayered","previousState":{"currentSnapshotID":"old","activeDiskLayers":{"Disk.asif":["Snapshots/Layers/original.asif"]}},"createdLayerPaths":["Snapshots/Layers/new.asif"]}"#.utf8)
            .write(to: temporaryRoot.appendingPathComponent(".restore-transaction.json"))

        try unwrapSuccess(VMSnapshotManager.recoverInterruptedRestore(vmRootPath: temporaryRoot))

        XCTAssertTrue(FileManager.default.fileExists(atPath: base.path))
        XCTAssertEqual(try read("config.json"), originalConfig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layers.appendingPathComponent("new.asif").path))
        let state = try JSONSerialization.jsonObject(
            with: Data(contentsOf: snapshots.appendingPathComponent("state.json"))
        ) as? [String: Any]
        XCTAssertEqual(state?["currentSnapshotID"] as? String, "old")
    }

    func testCommittedLayeredRestoreFinishesCleanupWithoutRollback() throws {
        let base = temporaryRoot.appendingPathComponent("Disk.asif")
        try Data([0x73, 0x68, 0x64, 0x77, 0x01]).write(to: base)
        try write("restored config", to: "config.json")
        let backup = temporaryRoot.appendingPathComponent(".restore-backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("old config".utf8).write(to: backup.appendingPathComponent("config.json"))
        try Data(#"{"snapshotID":"target","phase":"committed","kind":"diskImageKitLayered","createdLayerPaths":[]}"#.utf8)
            .write(to: temporaryRoot.appendingPathComponent(".restore-transaction.json"))

        try unwrapSuccess(VMSnapshotManager.recoverInterruptedRestore(vmRootPath: temporaryRoot))

        XCTAssertEqual(try read("config.json"), "restored config")
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: temporaryRoot.appendingPathComponent(".restore-transaction.json").path
        ))
    }

    func testLayeredRestoreRecoversAtEveryTransactionCheckpoint() throws {
        for checkpoint in VMSnapshotRestoreCheckpoint.allCases {
            let root = temporaryRoot.appendingPathComponent(String(describing: checkpoint), isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let diskURL = root.appendingPathComponent("Disk.asif")
            try unwrapSuccess(VMDiskImageManager.create(format: .asif, at: diskURL, size: 64 * 1024 * 1024))

            let targetConfig = #"{"marker":"target","storageDevices":[{"type":"Block","size":67108864,"imagePath":"Disk.asif","format":"asif"}]}"#
            let currentConfig = #"{"marker":"current","storageDevices":[{"type":"Block","size":67108864,"imagePath":"Disk.asif","format":"asif"}]}"#
            try Data(targetConfig.utf8).write(to: root.appendingPathComponent("config.json"))
            _ = try VMSnapshotManager.layeredDiskImage(baseURL: diskURL, vmRootPath: root)
            let target = try unwrapSuccess(
                VMSnapshotManager.createSnapshot(vmRootPath: root, name: "Target")
            )
            try Data(currentConfig.utf8).write(to: root.appendingPathComponent("config.json"))
            let current = try unwrapSuccess(
                VMSnapshotManager.createSnapshot(vmRootPath: root, name: "Current")
            )
            let layersURL = VMSnapshotManager.snapshotsRootURL(vmRootPath: root)
                .appendingPathComponent("Layers", isDirectory: true)
            let layersBeforeRestore = try Set(FileManager.default.contentsOfDirectory(atPath: layersURL.path))

            if case .success = VMSnapshotManager.restoreSnapshot(
                vmRootPath: root,
                snapshot: target,
                faultAt: checkpoint
            ) {
                XCTFail("Expected injected interruption at \(checkpoint)")
            }
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".restore-transaction.json").path
            ))

            try unwrapSuccess(VMSnapshotManager.recoverInterruptedRestore(vmRootPath: root))

            let committed = checkpoint == .journalCommitted
            let restoredConfig = try String(
                contentsOf: root.appendingPathComponent("config.json"),
                encoding: .utf8
            )
            XCTAssertEqual(restoredConfig, committed ? targetConfig : currentConfig, "Checkpoint: \(checkpoint)")
            XCTAssertEqual(
                VMSnapshotManager.currentSnapshotID(vmRootPath: root),
                committed ? target.id : current.id,
                "Checkpoint: \(checkpoint)"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: diskURL.path), "Checkpoint: \(checkpoint)")
            let layersAfterRecovery = try Set(FileManager.default.contentsOfDirectory(atPath: layersURL.path))
            if committed {
                XCTAssertEqual(layersAfterRecovery.count, layersBeforeRestore.count + 1, "Checkpoint: \(checkpoint)")
                XCTAssertTrue(layersBeforeRestore.isSubset(of: layersAfterRecovery), "Checkpoint: \(checkpoint)")
            } else {
                XCTAssertEqual(layersAfterRecovery, layersBeforeRestore, "Checkpoint: \(checkpoint)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".restore-staging").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".restore-backup").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".restore-transaction.json").path))
        }
    }

    func testProtectedSnapshotCannotBeDeletedUntilUnprotected() throws {
        try write("disk", to: "Disk.img")
        let snapshot = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Keep me")
        )
        try unwrapSuccess(VMSnapshotManager.setSnapshotProtected(
            vmRootPath: temporaryRoot,
            snapshot: snapshot,
            isProtected: true
        ))
        let protected = try XCTUnwrap(VMSnapshotManager.listSnapshots(vmRootPath: temporaryRoot).first)
        XCTAssertTrue(protected.isProtected)
        if case let .failure(message) = VMSnapshotManager.deleteSnapshot(vmRootPath: temporaryRoot, snapshot: protected) {
            XCTAssertTrue(message.contains("Unprotect"))
        } else {
            XCTFail("Protected snapshot was deleted")
        }
        try unwrapSuccess(VMSnapshotManager.setSnapshotProtected(
            vmRootPath: temporaryRoot,
            snapshot: protected,
            isProtected: false
        ))
        let unprotected = try XCTUnwrap(VMSnapshotManager.listSnapshots(vmRootPath: temporaryRoot).first)
        try unwrapSuccess(VMSnapshotManager.deleteSnapshot(vmRootPath: temporaryRoot, snapshot: unprotected))
    }

    private func write(_ value: String, to relativePath: String) throws {
        try Data(value.utf8).write(to: temporaryRoot.appendingPathComponent(relativePath))
    }

    private func read(_ relativePath: String) throws -> String {
        let data = try Data(contentsOf: temporaryRoot.appendingPathComponent(relativePath))
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func unwrapSuccess<T>(_ result: VMOSResult<T, String>) throws -> T {
        switch result {
        case .success(let value):
            return value
        case .failure(let message):
            throw TestFailure(message)
        }
    }

    private func unwrapSuccess(_ result: VMOSResultVoid) throws {
        if case .failure(let message) = result {
            throw TestFailure(message)
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
