import XCTest
@testable import EZVMCore

final class VMCreationDirectoryTransactionTests: XCTestCase {
    func testRollbackRemovesBundleCreatedByCurrentAttempt() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZVM-creation-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("New.ezvm", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let transaction = VMCreationDirectoryTransaction(rootURL: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: root.appendingPathComponent("Disk.asif"))

        try transaction.rollback()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRollbackNeverDeletesPreexistingDestination() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZVM-creation-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("Existing.ezvm", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sentinel = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)

        let transaction = VMCreationDirectoryTransaction(rootURL: root)
        try transaction.rollback()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }
}
