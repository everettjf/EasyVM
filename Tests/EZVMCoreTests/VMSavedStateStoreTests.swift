import Foundation
import XCTest
@testable import EZVMCore

final class VMSavedStateStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZVMSavedStateTests-\(UUID().uuidString)", isDirectory: true)
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

    func testInterruptedPendingSaveIsDiscardedWithoutRemovingCommittedState() throws {
        let state = root.appendingPathComponent("MachineState.vzvmsave")
        try Data("committed".utf8).write(to: state)
        let pending = VMSavedStateStore.pendingURL(for: state)
        try Data("partial".utf8).write(to: pending)

        VMSavedStateStore.recoverInterruptedTransaction(stateURL: state)

        XCTAssertEqual(try Data(contentsOf: state), Data("committed".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testInvalidBootLoaderErrorRecognitionIsNarrow() {
        XCTAssertTrue(VMEFIVariableStoreRecovery.isInvalidBootLoaderError(
            "Invalid virtual machine configuration. The boot loader is invalid."
        ))
        XCTAssertFalse(VMEFIVariableStoreRecovery.isInvalidBootLoaderError(
            "Invalid virtual machine configuration. The network device is invalid."
        ))
    }

    func testRejectedEFIStoreIsBackedUpAndReplaced() throws {
        let store = root.appendingPathComponent("NVRAM")
        try Data("damaged".utf8).write(to: store)

        let backup = try XCTUnwrap(VMEFIVariableStoreRecovery.replaceRejectedStore(at: store))

        XCTAssertEqual(try Data(contentsOf: backup), Data("damaged".utf8))
        XCTAssertGreaterThan(try Data(contentsOf: store).count, 1_024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathExtension("replacement").path))
    }
}
