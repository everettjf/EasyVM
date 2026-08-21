import Foundation
import XCTest
@testable import EasyVMCore

final class VMSnapshotManagerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyVMTests-\(UUID().uuidString)", isDirectory: true)
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
        let oldValue = UserDefaults.standard.object(forKey: EasyVMExperimentalFeatures.diskImageKitSnapshotsKey)
        defer {
            if let oldValue {
                UserDefaults.standard.set(oldValue, forKey: EasyVMExperimentalFeatures.diskImageKitSnapshotsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: EasyVMExperimentalFeatures.diskImageKitSnapshotsKey)
            }
        }
        UserDefaults.standard.set(true, forKey: EasyVMExperimentalFeatures.diskImageKitSnapshotsKey)
        try write("raw", to: "Disk.img")
        try write(#"{"storageDevices":[{"type":"Block","size":1024,"imagePath":"Disk.img","format":"raw"}]}"#, to: "config.json")

        XCTAssertEqual(VMSnapshotManager.selectedBackend(vmRootPath: temporaryRoot), .apfsClone)
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
