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

    func testManifestValidatesUnchangedConfigurationAndDisk() throws {
        let state = root.appendingPathComponent("MachineState.vzvmsave")
        try prepareMachineBundle()
        let pending = try VMSavedStateStore.prepare(stateURL: state)
        try Data("saved".utf8).write(to: pending)

        try VMSavedStateStore.commit(pendingURL: pending, stateURL: state, vmRootPath: root)

        XCTAssertEqual(VMSavedStateStore.compatibility(stateURL: state, vmRootPath: root), .compatible)
        XCTAssertTrue(FileManager.default.fileExists(atPath: VMSavedStateStore.manifestURL(for: state).path))
    }

    func testManifestIgnoresJSONFormattingOnlyChanges() throws {
        let state = root.appendingPathComponent("MachineState.vzvmsave")
        try prepareMachineBundle()
        let pending = try VMSavedStateStore.prepare(stateURL: state)
        try Data("saved".utf8).write(to: pending)
        try VMSavedStateStore.commit(pendingURL: pending, stateURL: state, vmRootPath: root)
        let reformatted = """
        {
          "storageDevices" : [
            { "imagePath" : "Disk.asif", "type" : "Block" }
          ]
        }
        """
        try Data(reformatted.utf8).write(to: root.appendingPathComponent("config.json"))

        XCTAssertEqual(VMSavedStateStore.compatibility(stateURL: state, vmRootPath: root), .compatible)
    }

    func testRecoveryFinalizesManifestAfterStateCommitBoundary() throws {
        let state = root.appendingPathComponent("MachineState.vzvmsave")
        try prepareMachineBundle()
        let pending = try VMSavedStateStore.prepare(stateURL: state)
        try Data("saved".utf8).write(to: pending)
        try VMSavedStateStore.commit(pendingURL: pending, stateURL: state, vmRootPath: root)
        let manifest = VMSavedStateStore.manifestURL(for: state)
        let pendingManifest = manifest.appendingPathExtension("pending")
        try FileManager.default.moveItem(at: manifest, to: pendingManifest)

        VMSavedStateStore.recoverInterruptedTransaction(stateURL: state)

        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingManifest.path))
        XCTAssertEqual(VMSavedStateStore.compatibility(stateURL: state, vmRootPath: root), .compatible)
    }

    func testManifestRejectsConfigurationChangedAfterSave() throws {
        let state = root.appendingPathComponent("MachineState.vzvmsave")
        try prepareMachineBundle()
        let pending = try VMSavedStateStore.prepare(stateURL: state)
        try Data("saved".utf8).write(to: pending)
        try VMSavedStateStore.commit(pendingURL: pending, stateURL: state, vmRootPath: root)
        let changed = #"{"name":"Changed","storageDevices":[{"type":"Block","imagePath":"Disk.asif"}]}"#
        try Data(changed.utf8).write(to: root.appendingPathComponent("config.json"))

        guard case let .incompatible(reason) = VMSavedStateStore.compatibility(
            stateURL: state,
            vmRootPath: root
        ) else {
            return XCTFail("A changed configuration must invalidate saved state")
        }
        XCTAssertTrue(reason.contains("configuration"))
    }

    func testManifestRejectsDiskChangedAfterSave() throws {
        let state = root.appendingPathComponent("MachineState.vzvmsave")
        try prepareMachineBundle()
        let pending = try VMSavedStateStore.prepare(stateURL: state)
        try Data("saved".utf8).write(to: pending)
        try VMSavedStateStore.commit(pendingURL: pending, stateURL: state, vmRootPath: root)
        try Data("disk changed and grew".utf8).write(to: root.appendingPathComponent("Disk.asif"))

        guard case let .incompatible(reason) = VMSavedStateStore.compatibility(
            stateURL: state,
            vmRootPath: root
        ) else {
            return XCTFail("A changed disk must invalidate saved state")
        }
        XCTAssertTrue(reason.contains("disk"))
    }

    func testManifestRejectsChangedActiveSnapshotBranch() throws {
        let state = root.appendingPathComponent("MachineState.vzvmsave")
        try prepareMachineBundle()
        let snapshots = VMSnapshotManager.snapshotsRootURL(vmRootPath: root)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try Data(#"{"activeDiskLayers":{}}"#.utf8).write(to: snapshots.appendingPathComponent("state.json"))
        let pending = try VMSavedStateStore.prepare(stateURL: state)
        try Data("saved".utf8).write(to: pending)
        try VMSavedStateStore.commit(pendingURL: pending, stateURL: state, vmRootPath: root)
        try Data(#"{"activeDiskLayers":{},"currentSnapshotID":"another"}"#.utf8)
            .write(to: snapshots.appendingPathComponent("state.json"))

        guard case let .incompatible(reason) = VMSavedStateStore.compatibility(
            stateURL: state,
            vmRootPath: root
        ) else {
            return XCTFail("A changed active snapshot branch must invalidate saved state")
        }
        XCTAssertTrue(reason.contains("snapshot"))
    }

    func testManifestCreationRejectsMalformedActiveLayerIndex() throws {
        let state = root.appendingPathComponent("MachineState.vzvmsave")
        try prepareMachineBundle()
        let snapshots = VMSnapshotManager.snapshotsRootURL(vmRootPath: root)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try Data(#"{"activeDiskLayers":"invalid"}"#.utf8)
            .write(to: snapshots.appendingPathComponent("state.json"))
        let pending = try VMSavedStateStore.prepare(stateURL: state)
        try Data("saved".utf8).write(to: pending)

        XCTAssertThrowsError(
            try VMSavedStateStore.commit(pendingURL: pending, stateURL: state, vmRootPath: root)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }

    func testManifestRejectsHardwareIdentityChangedAfterSave() throws {
        let state = root.appendingPathComponent("MachineState.vzvmsave")
        try prepareMachineBundle()
        let identifier = root.appendingPathComponent("MachineIdentifier")
        try Data("first identity".utf8).write(to: identifier)
        let pending = try VMSavedStateStore.prepare(stateURL: state)
        try Data("saved".utf8).write(to: pending)
        try VMSavedStateStore.commit(pendingURL: pending, stateURL: state, vmRootPath: root)
        try Data("second identity".utf8).write(to: identifier)

        guard case let .incompatible(reason) = VMSavedStateStore.compatibility(
            stateURL: state,
            vmRootPath: root
        ) else {
            return XCTFail("A changed hardware identity must invalidate saved state")
        }
        XCTAssertTrue(reason.contains("hardware identity"))
    }

    func testLegacyStateWithoutManifestRemainsOneTimeRestorable() throws {
        let state = root.appendingPathComponent("MachineState.vzvmsave")
        try Data("legacy".utf8).write(to: state)

        XCTAssertEqual(
            VMSavedStateStore.compatibility(stateURL: state, vmRootPath: root),
            .legacyUnverified
        )
    }

    func testColdBootNoticeIncludesTheSpecificReason() {
        let notice = VMSavedStateStore.coldBootNotice(reason: "the disk changed")

        XCTAssertTrue(notice.contains("because the disk changed"))
        XCTAssertTrue(notice.contains("starting normally"))
    }

    func testDamagedManifestFailsClosedAndDiscardRemovesAllArtifacts() throws {
        let state = root.appendingPathComponent("MachineState.vzvmsave")
        try Data("saved".utf8).write(to: state)
        let manifest = VMSavedStateStore.manifestURL(for: state)
        try Data("damaged".utf8).write(to: manifest)

        guard case .incompatible = VMSavedStateStore.compatibility(stateURL: state, vmRootPath: root) else {
            return XCTFail("A damaged manifest must prevent an unchecked restore")
        }
        VMSavedStateStore.discardCommitted(stateURL: state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
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

    private func prepareMachineBundle() throws {
        let config = #"{"storageDevices":[{"type":"Block","imagePath":"Disk.asif"}]}"#
        try Data(config.utf8).write(to: root.appendingPathComponent("config.json"))
        try Data("disk".utf8).write(to: root.appendingPathComponent("Disk.asif"))
    }
}
