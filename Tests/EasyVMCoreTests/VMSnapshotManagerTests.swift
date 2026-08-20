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
