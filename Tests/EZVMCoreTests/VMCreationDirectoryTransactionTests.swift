import XCTest
@testable import EZVMCore

final class VMCreationDirectoryTransactionTests: XCTestCase {
    func testRollbackRemovesBundleCreatedByCurrentAttempt() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZVM-creation-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("New.ezvm", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let transaction = VMCreationDirectoryTransaction(rootURL: root)
        try transaction.createRoot()
        try Data("partial".utf8).write(to: root.appendingPathComponent("Disk.asif"))

        XCTAssertTrue(transaction.ownsRoot)
        try transaction.rollback()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertFalse(transaction.ownsRoot)
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
        XCTAssertThrowsError(try transaction.createRoot()) { error in
            XCTAssertTrue(error.localizedDescription.contains("destination already exists"))
        }
        try transaction.rollback()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testDirectoryCreatedAfterTransactionInitializationIsNeverClaimedOrDeleted() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZVM-creation-race-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("Raced.ezvm", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let transaction = VMCreationDirectoryTransaction(rootURL: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let sentinel = root.appendingPathComponent("belongs-to-other-process")
        try Data("keep".utf8).write(to: sentinel)

        XCTAssertThrowsError(try transaction.createRoot())
        try transaction.rollback()
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testControlledStagingMayReuseOnlyItsExactDeclaredContentsWithoutOwningIt() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZVM-controlled-staging-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent(".Install.ezvm.install-token", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("verified-image".utf8).write(to: root.appendingPathComponent("Disk.img"))

        let transaction = VMCreationDirectoryTransaction(rootURL: root)
        try transaction.createRoot(allowedExistingItemNames: ["Disk.img"])
        XCTAssertFalse(transaction.ownsRoot)
        try transaction.rollback()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

        try Data("unexpected".utf8).write(to: root.appendingPathComponent("foreign-file"))
        let rejected = VMCreationDirectoryTransaction(rootURL: root)
        XCTAssertThrowsError(try rejected.createRoot(allowedExistingItemNames: ["Disk.img"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("unexpected files"))
        }
    }

    func testControlledStagingNeverFollowsASymbolicLink() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZVM-controlled-staging-link-\(UUID().uuidString)", isDirectory: true)
        let actual = parent.appendingPathComponent("actual", isDirectory: true)
        let link = parent.appendingPathComponent("staging", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try Data("verified-image".utf8).write(to: actual.appendingPathComponent("Disk.img"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)

        let transaction = VMCreationDirectoryTransaction(rootURL: link)
        XCTAssertThrowsError(try transaction.createRoot(allowedExistingItemNames: ["Disk.img"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("not a directory"))
        }
        try transaction.rollback()
        XCTAssertEqual(
            try Data(contentsOf: actual.appendingPathComponent("Disk.img")),
            Data("verified-image".utf8)
        )
    }
}
