import Foundation
import XCTest
@testable import EasyVMCore

final class VMSavedStateStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyVMSavedStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFailedSaveCanDiscardPendingWithoutChangingCurrentState() throws {
        let state = root.appendingPathComponent("MachineState.vzvmsave")
        try Data("current".utf8).write(to: state)
        let pending = try VMSavedStateStore.prepare(stateURL: state)
        try Data("partial".utf8).write(to: pending)

        VMSavedStateStore.discardPending(stateURL: state)

        XCTAssertEqual(try Data(contentsOf: state), Data("current".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testCommitAtomicallyReplacesCurrentState() throws {
        let state = root.appendingPathComponent("MachineState.vzvmsave")
        try Data("current".utf8).write(to: state)
        let pending = try VMSavedStateStore.prepare(stateURL: state)
        try Data("new".utf8).write(to: pending)

        try VMSavedStateStore.commit(pendingURL: pending, stateURL: state)

        XCTAssertEqual(try Data(contentsOf: state), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testCommitMovesFirstSavedStateIntoPlace() throws {
        let state = root.appendingPathComponent("MachineState.vzvmsave")
        let pending = try VMSavedStateStore.prepare(stateURL: state)
        try Data("first".utf8).write(to: pending)

        try VMSavedStateStore.commit(pendingURL: pending, stateURL: state)

        XCTAssertEqual(try Data(contentsOf: state), Data("first".utf8))
    }
}
