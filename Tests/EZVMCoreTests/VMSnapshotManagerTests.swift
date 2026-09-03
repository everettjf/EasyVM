import Foundation
import Darwin
import XCTest
@testable import EZVMCore

final class VMSnapshotManagerTests: XCTestCase {
    private static let realLowSpaceRootEnvironmentKey = "EZVM_REAL_LOW_SPACE_VOLUME"
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

    func testRealNearlyFullVolumeRejectsSnapshotBeforeMutation() throws {
        guard let volumePath = ProcessInfo.processInfo.environment[Self.realLowSpaceRootEnvironmentKey],
              !volumePath.isEmpty else {
            throw XCTSkip("Set \(Self.realLowSpaceRootEnvironmentKey) to run the isolated APFS capacity gate.")
        }
        let volume = URL(filePath: volumePath).standardizedFileURL
        let machine = volume.appendingPathComponent("NearFull.ezvm", isDirectory: true)
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)
        let disk = machine.appendingPathComponent("Disk.img")
        let original = Data(repeating: 0x5a, count: 8 * 1024 * 1024)
        try original.write(to: disk, options: .atomic)

        let available = try XCTUnwrap(VMStorageCapacity.availableBytes(at: machine))
        XCTAssertLessThan(
            available,
            1_073_741_824 + Int64(original.count),
            "The isolated volume is not full enough to exercise the real capacity failure."
        )
        let result = VMSnapshotManager.createSnapshot(
            vmRootPath: machine,
            name: "Must not be created"
        )
        guard case .failure(let message) = result else {
            return XCTFail("Expected the real-volume capacity preflight to reject the snapshot")
        }
        XCTAssertTrue(message.contains("available"), message)
        XCTAssertEqual(try Data(contentsOf: disk), original)
        XCTAssertTrue(VMSnapshotManager.listSnapshots(vmRootPath: machine).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: VMSnapshotManager.snapshotsRootURL(vmRootPath: machine).path
        ))
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

    func testLowSpaceAPFSSnapshotFailsBeforeCreatingSnapshot() throws {
        try Data(repeating: 0x41, count: 2 * 1024 * 1024)
            .write(to: temporaryRoot.appendingPathComponent("Disk.img"))

        let result = VMSnapshotManager.createSnapshot(
            vmRootPath: temporaryRoot,
            name: "No room",
            availableCapacityBytes: 0
        )

        guard case .failure(let message) = result else {
            return XCTFail("Expected low-space snapshot failure")
        }
        XCTAssertTrue(message.contains("available"), message)
        XCTAssertTrue(VMSnapshotManager.listSnapshots(vmRootPath: temporaryRoot).isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: temporaryRoot.appendingPathComponent("Disk.img")),
            Data(repeating: 0x41, count: 2 * 1024 * 1024)
        )
    }

    func testLowSpaceAPFSRestoreLeavesMachineAndTransactionStateUntouched() throws {
        try write("snapshot disk", to: "Disk.img")
        let snapshot = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Target")
        )
        try write("current disk", to: "Disk.img")

        let result = VMSnapshotManager.restoreSnapshot(
            vmRootPath: temporaryRoot,
            snapshot: snapshot,
            availableCapacityBytes: 0
        )

        guard case .failure(let message) = result else {
            return XCTFail("Expected low-space restore failure")
        }
        XCTAssertTrue(message.contains("available"), message)
        XCTAssertEqual(try read("Disk.img"), "current disk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRoot.appendingPathComponent(".restore-transaction.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRoot.appendingPathComponent(".restore-staging").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRoot.appendingPathComponent(".restore-backup").path))
    }

    func testRestoreStorageEstimateIncludesStagingSafetySnapshotAndReserve() throws {
        try Data(repeating: 0x41, count: 2 * 1024 * 1024)
            .write(to: temporaryRoot.appendingPathComponent("Disk.img"))
        try write("snapshot config", to: "config.json")
        let snapshot = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Target")
        )
        try Data(repeating: 0x42, count: 3 * 1024 * 1024)
            .write(to: temporaryRoot.appendingPathComponent("Disk.img"))
        try write("current config", to: "config.json")

        let estimate = try unwrapSuccess(VMSnapshotManager.restoreStorageEstimate(
            vmRootPath: temporaryRoot,
            snapshot: snapshot,
            keepCurrentState: true,
            availableCapacityBytes: Int64.max
        ))

        XCTAssertGreaterThan(estimate.restoreStagingBytes, 0)
        XCTAssertGreaterThan(estimate.safetySnapshotBytes, estimate.restoreStagingBytes)
        XCTAssertEqual(estimate.reserveBytes, VMStorageCapacity.defaultReserveBytes)
        XCTAssertEqual(
            estimate.requiredAvailableBytes,
            estimate.restoreStagingBytes + estimate.safetySnapshotBytes + estimate.reserveBytes
        )
        XCTAssertEqual(estimate.hasEnoughSpace, true)
    }

    func testRestoreStorageEstimateOmitsSafetySnapshotWhenUserAcceptsReplacement() throws {
        try write("snapshot disk", to: "Disk.img")
        let snapshot = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Target")
        )
        try write("current disk", to: "Disk.img")

        let estimate = try unwrapSuccess(VMSnapshotManager.restoreStorageEstimate(
            vmRootPath: temporaryRoot,
            snapshot: snapshot,
            keepCurrentState: false,
            availableCapacityBytes: 0
        ))

        XCTAssertEqual(estimate.safetySnapshotBytes, 0)
        XCTAssertEqual(
            estimate.requiredAvailableBytes,
            estimate.restoreStagingBytes + estimate.reserveBytes
        )
        XCTAssertEqual(estimate.hasEnoughSpace, false)
    }

    func testRestoreStorageEstimateRejectsDamagedSnapshotBeforeReview() throws {
        try write("snapshot disk", to: "Disk.img")
        let snapshot = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Target")
        )
        try write("tampered", to: "Snapshots/\(snapshot.id)/files/Disk.img")

        let result = VMSnapshotManager.restoreStorageEstimate(
            vmRootPath: temporaryRoot,
            snapshot: snapshot,
            keepCurrentState: false,
            availableCapacityBytes: Int64.max
        )

        guard case let .failure(message) = result else {
            return XCTFail("A damaged snapshot must not produce a restore review")
        }
        XCTAssertTrue(message.contains("integrity"), message)
    }

    func testRestoreStorageEstimateSaturatesPathologicalTotals() {
        let estimate = VMSnapshotRestoreStorageEstimate(
            restoreStagingBytes: Int64.max,
            safetySnapshotBytes: Int64.max,
            reserveBytes: Int64.max,
            availableBytes: Int64.max
        )

        XCTAssertEqual(estimate.temporaryOperationBytes, Int64.max)
        XCTAssertEqual(estimate.requiredAvailableBytes, Int64.max)
        XCTAssertEqual(estimate.hasEnoughSpace, true)
    }

    func testCancelledAPFSSnapshotRemovesPartialOutputAndReportsRealProgress() throws {
        try Data(repeating: 0x41, count: 1024 * 1024)
            .write(to: temporaryRoot.appendingPathComponent("Disk.img"))
        try Data(repeating: 0x42, count: 1024 * 1024)
            .write(to: temporaryRoot.appendingPathComponent("config.json"))
        let control = VMSnapshotOperationControl()
        var updates: [VMSnapshotOperationProgress] = []

        let result = VMSnapshotManager.createSnapshot(
            vmRootPath: temporaryRoot,
            name: "Cancelled",
            operationControl: control
        ) { update in
            updates.append(update)
            if update.phase == .copying, update.completedUnitCount > 0 {
                control.cancel()
            }
        }

        guard case .failure(let message) = result else {
            return XCTFail("Expected snapshot creation to be cancelled")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("cancelled"), message)
        XCTAssertTrue(updates.contains { $0.phase == .preparing && $0.canCancel })
        XCTAssertTrue(updates.contains { $0.phase == .copying && $0.completedUnitCount > 0 })
        XCTAssertFalse(updates.contains { $0.phase == .committing })
        XCTAssertTrue(VMSnapshotManager.listSnapshots(vmRootPath: temporaryRoot).isEmpty)
        XCTAssertEqual(try Data(contentsOf: temporaryRoot.appendingPathComponent("Disk.img")), Data(repeating: 0x41, count: 1024 * 1024))
        XCTAssertEqual(try Data(contentsOf: temporaryRoot.appendingPathComponent("config.json")), Data(repeating: 0x42, count: 1024 * 1024))
    }

    func testCancelledAPFSRestoreBeforeCommitPreservesMachineAndCleansTransaction() throws {
        try Data(repeating: 0x31, count: 1024 * 1024)
            .write(to: temporaryRoot.appendingPathComponent("Disk.img"))
        try Data(repeating: 0x32, count: 1024 * 1024)
            .write(to: temporaryRoot.appendingPathComponent("config.json"))
        let snapshot = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Target")
        )
        let currentDisk = Data(repeating: 0x51, count: 1024 * 1024)
        let currentConfiguration = Data(repeating: 0x52, count: 1024 * 1024)
        try currentDisk.write(to: temporaryRoot.appendingPathComponent("Disk.img"), options: .atomic)
        try currentConfiguration.write(to: temporaryRoot.appendingPathComponent("config.json"), options: .atomic)
        let control = VMSnapshotOperationControl()
        var updates: [VMSnapshotOperationProgress] = []

        let result = VMSnapshotManager.restoreSnapshot(
            vmRootPath: temporaryRoot,
            snapshot: snapshot,
            operationControl: control
        ) { update in
            updates.append(update)
            if update.phase == .copying, update.completedUnitCount > 0 {
                control.cancel()
            }
        }

        guard case .failure(let message) = result else {
            return XCTFail("Expected snapshot restore to be cancelled")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("cancelled"), message)
        XCTAssertFalse(updates.contains { $0.phase == .committing })
        XCTAssertEqual(try Data(contentsOf: temporaryRoot.appendingPathComponent("Disk.img")), currentDisk)
        XCTAssertEqual(try Data(contentsOf: temporaryRoot.appendingPathComponent("config.json")), currentConfiguration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRoot.appendingPathComponent(".restore-transaction.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRoot.appendingPathComponent(".restore-staging").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRoot.appendingPathComponent(".restore-backup").path))
    }

    func testCancellationAfterAPFSRestoreCommitBoundaryDoesNotInterruptTransaction() throws {
        try write("snapshot disk", to: "Disk.img")
        try write("snapshot config", to: "config.json")
        let snapshot = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Target")
        )
        try write("current disk", to: "Disk.img")
        try write("current config", to: "config.json")
        let control = VMSnapshotOperationControl()
        var reachedNoncancellableCommit = false

        let result = VMSnapshotManager.restoreSnapshot(
            vmRootPath: temporaryRoot,
            snapshot: snapshot,
            operationControl: control
        ) { update in
            if update.phase == .committing {
                reachedNoncancellableCommit = true
                XCTAssertFalse(update.canCancel)
                control.cancel()
            }
        }

        try unwrapSuccess(result)
        XCTAssertTrue(reachedNoncancellableCommit)
        XCTAssertEqual(try read("Disk.img"), "snapshot disk")
        XCTAssertEqual(try read("config.json"), "snapshot config")
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
            VMSnapshotManager.createSnapshot(
                vmRootPath: temporaryRoot,
                name: "Layered",
                isProtected: true
            )
        )
        XCTAssertEqual(snapshot.backend, .diskImageKitLayered)
        XCTAssertTrue(snapshot.isProtected)
        XCTAssertEqual(snapshot.diskLayers.count, 1)
        XCTAssertEqual(snapshot.diskLayers[0].baseImageName, "Disk.asif")
        XCTAssertEqual(snapshot.diskLayers[0].layerPaths.count, 1)
        XCTAssertTrue(VMSnapshotManager.auditSnapshot(vmRootPath: temporaryRoot, snapshot: snapshot).isValid)

        try unwrapSuccess(VMSnapshotManager.restoreSnapshot(vmRootPath: temporaryRoot, snapshot: snapshot))
        XCTAssertEqual(VMSnapshotManager.currentSnapshotID(vmRootPath: temporaryRoot), snapshot.id)
    }

    func testLowSpaceLayeredSnapshotFailsBeforeCreatingFilesOrLayers() throws {
        let diskURL = temporaryRoot.appendingPathComponent("Disk.asif")
        try unwrapSuccess(VMDiskImageManager.create(format: .asif, at: diskURL, size: 64 * 1024 * 1024))
        try write(
            #"{"storageDevices":[{"type":"Block","size":67108864,"imagePath":"Disk.asif","format":"asif"}]}"#,
            to: "config.json"
        )
        try Data(repeating: 0x43, count: 2 * 1024 * 1024)
            .write(to: temporaryRoot.appendingPathComponent("metadata.bin"))
        _ = try VMSnapshotManager.layeredDiskImage(baseURL: diskURL, vmRootPath: temporaryRoot)
        let layersURL = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
            .appendingPathComponent("Layers", isDirectory: true)
        let layersBefore = try Set(FileManager.default.contentsOfDirectory(atPath: layersURL.path))

        let result = VMSnapshotManager.createSnapshot(
            vmRootPath: temporaryRoot,
            name: "No room",
            availableCapacityBytes: 0
        )

        guard case .failure(let message) = result else {
            return XCTFail("Expected low-space layered snapshot failure")
        }
        XCTAssertTrue(message.contains("available"), message)
        XCTAssertTrue(VMSnapshotManager.listSnapshots(vmRootPath: temporaryRoot).isEmpty)
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: layersURL.path)),
            layersBefore
        )
    }

    func testLowSpaceLayeredRestoreLeavesCurrentBranchAndLayersUntouched() throws {
        let root = temporaryRoot.appendingPathComponent("low-space-layered-restore", isDirectory: true)
        let fixture = try makeLayeredRestoreFixture(at: root)
        let layersURL = VMSnapshotManager.snapshotsRootURL(vmRootPath: root)
            .appendingPathComponent("Layers", isDirectory: true)
        let layersBefore = try Set(FileManager.default.contentsOfDirectory(atPath: layersURL.path))

        let result = VMSnapshotManager.restoreSnapshot(
            vmRootPath: root,
            snapshot: fixture.target,
            availableCapacityBytes: 0
        )

        guard case .failure(let message) = result else {
            return XCTFail("Expected low-space layered restore failure")
        }
        XCTAssertTrue(message.contains("available"), message)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("config.json"), encoding: .utf8),
            fixture.currentConfig
        )
        XCTAssertEqual(VMSnapshotManager.currentSnapshotID(vmRootPath: root), fixture.current.id)
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: layersURL.path)),
            layersBefore
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".restore-transaction.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".restore-staging").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".restore-backup").path))
    }

    func testCancelledLayeredRestoreRollsBackNewOverlayAndPreservesCurrentBranch() throws {
        let root = temporaryRoot.appendingPathComponent("cancelled-layered-restore", isDirectory: true)
        let fixture = try makeLayeredRestoreFixture(at: root)
        let layersURL = VMSnapshotManager.snapshotsRootURL(vmRootPath: root)
            .appendingPathComponent("Layers", isDirectory: true)
        let layersBefore = try Set(FileManager.default.contentsOfDirectory(atPath: layersURL.path))
        let control = VMSnapshotOperationControl()
        var reachedCopying = false

        let result = VMSnapshotManager.restoreSnapshot(
            vmRootPath: root,
            snapshot: fixture.target,
            operationControl: control
        ) { update in
            if update.phase == .copying {
                reachedCopying = true
                control.cancel()
            }
        }

        guard case .failure(let message) = result else {
            return XCTFail("Expected layered restore to be cancelled")
        }
        XCTAssertTrue(reachedCopying)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("cancelled"), message)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("config.json"), encoding: .utf8),
            fixture.currentConfig
        )
        XCTAssertEqual(VMSnapshotManager.currentSnapshotID(vmRootPath: root), fixture.current.id)
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: layersURL.path)), layersBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".restore-transaction.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".restore-staging").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".restore-backup").path))
    }

    func testMissingASIFBaseIsNotSilentlyRecreatedWhenLayersDependOnIt() throws {
        let diskURL = try prepareLayeredASIFMachine(at: temporaryRoot)
        _ = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Depends on base")
        )
        let layersURL = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
            .appendingPathComponent("Layers", isDirectory: true)
        let layersBefore = try Set(FileManager.default.contentsOfDirectory(atPath: layersURL.path))
        try FileManager.default.removeItem(at: diskURL)

        let result = VMSnapshotManager.validateExistingASIFBaseDependency(
            baseURL: diskURL,
            vmRootPath: temporaryRoot
        )

        guard case .failure(let message) = result else {
            return XCTFail("Expected a missing dependent ASIF base to block startup")
        }
        XCTAssertTrue(message.contains("did not create a replacement"), message)
        XCTAssertTrue(message.contains("Restore the original base image"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: diskURL.path))
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: layersURL.path)),
            layersBefore
        )
    }

    func testInvalidASIFBaseIsPreservedForDiagnosisWhenLayersDependOnIt() throws {
        let diskURL = try prepareLayeredASIFMachine(at: temporaryRoot)
        let invalidData = Data("not-an-asif-base".utf8)
        try invalidData.write(to: diskURL)

        let result = VMSnapshotManager.validateExistingASIFBaseDependency(
            baseURL: diskURL,
            vmRootPath: temporaryRoot
        )

        guard case .failure(let message) = result else {
            return XCTFail("Expected an invalid dependent ASIF base to block startup")
        }
        XCTAssertTrue(message.contains("missing or invalid"), message)
        XCTAssertEqual(try Data(contentsOf: diskURL), invalidData)
    }

    func testForeignValidASIFBaseCannotOpenExistingLayerStackAndIsPreserved() throws {
        let diskURL = try prepareLayeredASIFMachine(at: temporaryRoot)
        let replacementURL = temporaryRoot.appendingPathComponent("Replacement.asif")
        try unwrapSuccess(VMDiskImageManager.create(format: .asif, at: replacementURL, size: 64 * 1024 * 1024))
        try FileManager.default.removeItem(at: diskURL)
        try FileManager.default.moveItem(at: replacementURL, to: diskURL)
        let replacementSize = try XCTUnwrap(
            diskURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )

        let result = VMSnapshotManager.validateExistingASIFBaseDependency(
            baseURL: diskURL,
            vmRootPath: temporaryRoot
        )

        guard case .failure(let message) = result else {
            return XCTFail("Expected a foreign ASIF base to fail its existing parent chain")
        }
        XCTAssertTrue(message.contains("does not match its active layer stack"), message)
        XCTAssertTrue(message.contains("did not modify the disk chain"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diskURL.path))
        XCTAssertEqual(try diskURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, replacementSize)
    }

    func testMissingActiveASIFLayerFailsBeforeStartupWithoutPruningOtherLayers() throws {
        let diskURL = try prepareLayeredASIFMachine(at: temporaryRoot)
        let layersURL = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
            .appendingPathComponent("Layers", isDirectory: true)
        let layerNames = try FileManager.default.contentsOfDirectory(atPath: layersURL.path)
        let missingLayer = try XCTUnwrap(layerNames.first)
        try FileManager.default.removeItem(at: layersURL.appendingPathComponent(missingLayer))

        let result = VMSnapshotManager.validateExistingASIFBaseDependency(
            baseURL: diskURL,
            vmRootPath: temporaryRoot
        )

        guard case .failure(let message) = result else {
            return XCTFail("Expected a missing active layer to block startup")
        }
        XCTAssertTrue(message.contains("layer is missing or damaged"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diskURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layersURL.path))
    }

    func testASIFAuditRejectsAReorderedLayerStack() throws {
        let root = temporaryRoot.appendingPathComponent("reordered-stack", isDirectory: true)
        let fixture = try makeLayeredRestoreFixture(at: root)
        let disk = try XCTUnwrap(fixture.current.diskLayers.first)
        XCTAssertGreaterThanOrEqual(disk.layerPaths.count, 2)
        let reordered = VMSnapshotModel(
            id: fixture.current.id,
            name: fixture.current.name,
            createdAt: fixture.current.createdAt,
            parentSnapshotID: fixture.current.parentSnapshotID,
            totalSize: fixture.current.totalSize,
            backend: fixture.current.backend,
            diskLayers: [VMSnapshotDiskLayer(
                baseImageName: disk.baseImageName,
                layerPaths: disk.layerPaths.reversed()
            )],
            fileManifest: fixture.current.fileManifest,
            isProtected: fixture.current.isProtected
        )
        try writeSnapshotMetadata(reordered, at: root)

        let report = VMSnapshotManager.auditSnapshot(vmRootPath: root, snapshot: reordered)

        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.errors.contains { $0.contains("stack order or parent relationship") })
    }

    func testASIFLongChainIsUsableAndReportsAdvisoryDepth() throws {
        let root = temporaryRoot.appendingPathComponent("long-stack", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let diskURL = root.appendingPathComponent("Disk.asif")
        try unwrapSuccess(VMDiskImageManager.create(format: .asif, at: diskURL, size: 64 * 1024 * 1024))
        let config = #"{"storageDevices":[{"type":"Block","size":67108864,"imagePath":"Disk.asif","format":"asif"}]}"#
        try Data(config.utf8).write(to: root.appendingPathComponent("config.json"))
        _ = try VMSnapshotManager.layeredDiskImage(baseURL: diskURL, vmRootPath: root)

        var latest: VMSnapshotModel?
        for index in 1...VMSnapshotManager.recommendedMaximumASIFLayerDepth {
            latest = try unwrapSuccess(
                VMSnapshotManager.createSnapshot(vmRootPath: root, name: "Layer \(index)")
            )
        }
        let snapshot = try XCTUnwrap(latest)
        let report = VMSnapshotManager.auditSnapshot(vmRootPath: root, snapshot: snapshot)

        XCTAssertTrue(report.isValid, report.errors.joined(separator: "; "))
        XCTAssertTrue(report.warnings.contains { $0.contains("32 layers deep") })
        XCTAssertTrue(report.warnings.contains { $0.contains("does not compact layered ASIF disks in place") })
        XCTAssertFalse(report.warnings.contains { $0.localizedCaseInsensitiveContains("consolidat") })
        XCTAssertEqual(
            VMSnapshotManager.maximumASIFLayerDepth(vmRootPath: root),
            VMSnapshotManager.recommendedMaximumASIFLayerDepth + 1
        )
        XCTAssertNotNil(try VMSnapshotManager.layeredDiskImage(baseURL: diskURL, vmRootPath: root))
    }

    func testLargeSparseASIFSnapshotRestorePreservesLogicalCapacity() throws {
        let root = temporaryRoot.appendingPathComponent("large-sparse", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let diskURL = root.appendingPathComponent("Disk.asif")
        let logicalSize: UInt64 = 64 * 1024 * 1024 * 1024
        try unwrapSuccess(VMDiskImageManager.create(
            format: .asif,
            at: diskURL,
            size: logicalSize
        ))
        let originalConfig = #"{"marker":"before","storageDevices":[{"type":"Block","size":68719476736,"imagePath":"Disk.asif","format":"asif"}]}"#
        try Data(originalConfig.utf8).write(to: root.appendingPathComponent("config.json"))

        let initial = try XCTUnwrap(VMSnapshotManager.layeredDiskImage(
            baseURL: diskURL,
            vmRootPath: root
        ))
        XCTAssertEqual(initial.size, Int(logicalSize))
        let snapshot = try unwrapSuccess(VMSnapshotManager.createSnapshot(
            vmRootPath: root,
            name: "64 GiB"
        ))
        XCTAssertTrue(VMSnapshotManager.auditSnapshot(
            vmRootPath: root,
            snapshot: snapshot
        ).isValid)

        let changedConfig = originalConfig.replacingOccurrences(of: "before", with: "after")
        try Data(changedConfig.utf8).write(to: root.appendingPathComponent("config.json"))
        try unwrapSuccess(VMSnapshotManager.restoreSnapshot(
            vmRootPath: root,
            snapshot: snapshot
        ))

        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("config.json"), encoding: .utf8),
            originalConfig
        )
        let restored = try XCTUnwrap(VMSnapshotManager.layeredDiskImage(
            baseURL: diskURL,
            vmRootPath: root
        ))
        XCTAssertEqual(restored.size, Int(logicalSize))
        XCTAssertTrue(VMSnapshotManager.auditSnapshot(
            vmRootPath: root,
            snapshot: snapshot
        ).isValid)
    }

    func testASIFBranchRestoreAndLeafDeletionPruneOnlyUnreferencedLayers() throws {
        let root = temporaryRoot.appendingPathComponent("branch-pruning", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let diskURL = root.appendingPathComponent("Disk.asif")
        try unwrapSuccess(VMDiskImageManager.create(format: .asif, at: diskURL, size: 64 * 1024 * 1024))
        let config = #"{"storageDevices":[{"type":"Block","size":67108864,"imagePath":"Disk.asif","format":"asif"}]}"#
        try Data(config.utf8).write(to: root.appendingPathComponent("config.json"))
        _ = try VMSnapshotManager.layeredDiskImage(baseURL: diskURL, vmRootPath: root)
        let branchPoint = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: root, name: "Branch point")
        )
        let oldLeaf = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: root, name: "Old leaf")
        )
        let layersURL = VMSnapshotManager.snapshotsRootURL(vmRootPath: root)
            .appendingPathComponent("Layers", isDirectory: true)
        let beforeRestore = try Set(FileManager.default.contentsOfDirectory(atPath: layersURL.path))
        let oldLeafReferences = Set(try XCTUnwrap(oldLeaf.diskLayers.first).layerPaths.map {
            URL(fileURLWithPath: $0).lastPathComponent
        })
        let abandonedHead = try XCTUnwrap(beforeRestore.subtracting(oldLeafReferences).first)

        try unwrapSuccess(VMSnapshotManager.restoreSnapshot(vmRootPath: root, snapshot: branchPoint))

        let afterRestore = try Set(FileManager.default.contentsOfDirectory(atPath: layersURL.path))
        XCTAssertFalse(afterRestore.contains(abandonedHead))
        XCTAssertTrue(oldLeafReferences.isSubset(of: afterRestore))
        XCTAssertEqual(afterRestore.count, beforeRestore.count)

        try unwrapSuccess(VMSnapshotManager.deleteSnapshot(vmRootPath: root, snapshot: oldLeaf))

        let afterLeafDeletion = try Set(FileManager.default.contentsOfDirectory(atPath: layersURL.path))
        let branchPointReferences = Set(try XCTUnwrap(branchPoint.diskLayers.first).layerPaths.map {
            URL(fileURLWithPath: $0).lastPathComponent
        })
        XCTAssertTrue(branchPointReferences.isSubset(of: afterLeafDeletion))
        XCTAssertEqual(afterLeafDeletion.count, branchPointReferences.count + 1)
        XCTAssertTrue(VMSnapshotManager.auditSnapshot(vmRootPath: root, snapshot: branchPoint).isValid)
    }

    func testASIFLayerPruningStopsWhenSnapshotMetadataIndexIsIncomplete() throws {
        guard #available(macOS 27.0, *) else { return }
        let root = temporaryRoot.appendingPathComponent("damaged-index", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let diskURL = try prepareLayeredASIFMachine(at: root)
        let snapshot = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: root, name: "Valid snapshot")
        )
        XCTAssertNotNil(try VMSnapshotManager.layeredDiskImage(baseURL: diskURL, vmRootPath: root))

        let snapshotsRoot = VMSnapshotManager.snapshotsRootURL(vmRootPath: root)
        let damagedID = UUID().uuidString
        let damagedDirectory = snapshotsRoot.appendingPathComponent(damagedID, isDirectory: true)
        try FileManager.default.createDirectory(at: damagedDirectory, withIntermediateDirectories: true)
        try Data("not valid snapshot metadata".utf8)
            .write(to: damagedDirectory.appendingPathComponent("snapshot.json"))

        let layersRoot = snapshotsRoot.appendingPathComponent("Layers", isDirectory: true)
        let preservedLayer = layersRoot.appendingPathComponent("possibly-referenced.asif")
        try Data("preserve while index is damaged".utf8).write(to: preservedLayer)

        try unwrapSuccess(VMSnapshotManager.deleteSnapshot(vmRootPath: root, snapshot: snapshot))

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: preservedLayer.path),
            "No ASIF layer may be deleted while snapshot references are incomplete"
        )
    }

    func testASIFLayerPruningStopsWhenActiveStateIsUnreadable() throws {
        try write("disk", to: "Disk.img")
        let snapshot = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Delete me")
        )
        let snapshotsRoot = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
        let layersRoot = snapshotsRoot.appendingPathComponent("Layers", isDirectory: true)
        try FileManager.default.createDirectory(at: layersRoot, withIntermediateDirectories: true)
        let preservedLayer = layersRoot.appendingPathComponent("\(UUID().uuidString).asif")
        try Data("possibly active".utf8).write(to: preservedLayer)
        try Data("damaged state".utf8).write(to: snapshotsRoot.appendingPathComponent("state.json"))

        try unwrapSuccess(VMSnapshotManager.deleteSnapshot(vmRootPath: temporaryRoot, snapshot: snapshot))

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: preservedLayer.path),
            "Automatic pruning must preserve all layers when active state cannot be decoded"
        )
    }

    func testSnapshotMaintenancePreviewFindsOnlyUnreferencedOwnedLayers() throws {
        let snapshotsRoot = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
        let layersRoot = snapshotsRoot.appendingPathComponent("Layers", isDirectory: true)
        try FileManager.default.createDirectory(at: layersRoot, withIntermediateDirectories: true)
        let referencedName = "\(UUID().uuidString).asif"
        let orphanName = "\(UUID().uuidString).asif"
        try Data(repeating: 0x61, count: 8192).write(to: layersRoot.appendingPathComponent(referencedName))
        try Data(repeating: 0x62, count: 8192).write(to: layersRoot.appendingPathComponent(orphanName))
        try Data("leave unknown files alone".utf8).write(to: layersRoot.appendingPathComponent("manual.asif"))
        let state = #"{"activeDiskLayers":{"Disk.asif":["Snapshots/Layers/\#(referencedName)"]}}"#
        try Data(state.utf8).write(to: snapshotsRoot.appendingPathComponent("state.json"))

        let report = VMSnapshotManager.snapshotMaintenanceReport(vmRootPath: temporaryRoot)

        XCTAssertTrue(report.issues.isEmpty, report.issues.joined(separator: "; "))
        XCTAssertEqual(report.removableLayers.map(\.relativePath), ["Snapshots/Layers/\(orphanName)"])
        XCTAssertGreaterThan(report.removableAllocatedSize, 0)
        XCTAssertEqual(report.retainedLayerCount, 2)
        XCTAssertTrue(report.canClean)
    }

    func testSnapshotMaintenancePreviewTreatsMissingStoreAsAlreadyClean() {
        let report = VMSnapshotManager.snapshotMaintenanceReport(vmRootPath: temporaryRoot)

        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertTrue(report.removableLayers.isEmpty)
        XCTAssertFalse(report.canClean)
    }

    func testSnapshotMaintenancePreviewBlocksWhenActiveStateIsUnreadable() throws {
        let snapshotsRoot = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
        let layersRoot = snapshotsRoot.appendingPathComponent("Layers", isDirectory: true)
        try FileManager.default.createDirectory(at: layersRoot, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: layersRoot.appendingPathComponent("\(UUID().uuidString).asif"))
        try Data("damaged state".utf8).write(to: snapshotsRoot.appendingPathComponent("state.json"))

        let report = VMSnapshotManager.snapshotMaintenanceReport(vmRootPath: temporaryRoot)

        XCTAssertFalse(report.issues.isEmpty)
        XCTAssertTrue(report.removableLayers.isEmpty)
        XCTAssertFalse(report.canClean)
    }

    func testSnapshotMaintenancePreviewBlocksDuringRestoreOrIncompleteMetadata() throws {
        let snapshotsRoot = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
        let layersRoot = snapshotsRoot.appendingPathComponent("Layers", isDirectory: true)
        try FileManager.default.createDirectory(at: layersRoot, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: layersRoot.appendingPathComponent("\(UUID().uuidString).asif"))
        let damagedSnapshot = snapshotsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: damagedSnapshot, withIntermediateDirectories: true)
        try Data("damaged metadata".utf8).write(to: damagedSnapshot.appendingPathComponent("snapshot.json"))
        try Data(#"{"snapshotID":"target","phase":"preparing"}"#.utf8)
            .write(to: temporaryRoot.appendingPathComponent(".restore-transaction.json"))

        let report = VMSnapshotManager.snapshotMaintenanceReport(vmRootPath: temporaryRoot)

        XCTAssertGreaterThanOrEqual(report.issues.count, 2)
        XCTAssertTrue(report.removableLayers.isEmpty)
        XCTAssertFalse(report.canClean)
    }

    func testSnapshotLayerCleanupRemovesOnlyPreviewedOwnedOrphans() throws {
        let snapshotsRoot = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
        let layersRoot = snapshotsRoot.appendingPathComponent("Layers", isDirectory: true)
        try FileManager.default.createDirectory(at: layersRoot, withIntermediateDirectories: true)
        let referencedName = "\(UUID().uuidString).asif"
        let orphanName = "\(UUID().uuidString).asif"
        try Data("referenced".utf8).write(to: layersRoot.appendingPathComponent(referencedName))
        try Data("orphan".utf8).write(to: layersRoot.appendingPathComponent(orphanName))
        try Data("unknown".utf8).write(to: layersRoot.appendingPathComponent("manual.asif"))
        let state = #"{"activeDiskLayers":{"Disk.asif":["Snapshots/Layers/\#(referencedName)"]}}"#
        try Data(state.utf8).write(to: snapshotsRoot.appendingPathComponent("state.json"))

        let result = try unwrapSuccess(VMSnapshotManager.cleanupUnreferencedLayers(vmRootPath: temporaryRoot))

        XCTAssertEqual(result.removedLayerCount, 1)
        XCTAssertGreaterThan(result.reclaimedAllocatedSize, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layersRoot.appendingPathComponent(orphanName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layersRoot.appendingPathComponent(referencedName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layersRoot.appendingPathComponent("manual.asif").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotsRoot.appendingPathComponent(".layer-cleanup-transaction.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotsRoot.appendingPathComponent(".layer-cleanup-quarantine").path))
    }

    func testInterruptedUncommittedLayerCleanupRestoresQuarantinedFilesBeforeStartup() throws {
        let snapshotsRoot = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
        let layersRoot = snapshotsRoot.appendingPathComponent("Layers", isDirectory: true)
        let quarantine = snapshotsRoot.appendingPathComponent(".layer-cleanup-quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: layersRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let layerName = "\(UUID().uuidString).asif"
        try Data("must return".utf8).write(to: quarantine.appendingPathComponent(layerName))
        let journal = #"{"phase":"preparing","layerNames":["\#(layerName)"]}"#
        try Data(journal.utf8).write(to: snapshotsRoot.appendingPathComponent(".layer-cleanup-transaction.json"))

        try unwrapSuccess(VMSnapshotManager.recoverInterruptedRestore(vmRootPath: temporaryRoot))

        XCTAssertEqual(
            try Data(contentsOf: layersRoot.appendingPathComponent(layerName)),
            Data("must return".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotsRoot.appendingPathComponent(".layer-cleanup-transaction.json").path))
    }

    func testInterruptedCommittedLayerCleanupFinishesReclamationBeforeStartup() throws {
        let snapshotsRoot = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
        let quarantine = snapshotsRoot.appendingPathComponent(".layer-cleanup-quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let layerName = "\(UUID().uuidString).asif"
        try Data("remove me".utf8).write(to: quarantine.appendingPathComponent(layerName))
        let journal = #"{"phase":"committed","layerNames":["\#(layerName)"]}"#
        try Data(journal.utf8).write(to: snapshotsRoot.appendingPathComponent(".layer-cleanup-transaction.json"))

        try unwrapSuccess(VMSnapshotManager.recoverInterruptedRestore(vmRootPath: temporaryRoot))

        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotsRoot.appendingPathComponent(".layer-cleanup-transaction.json").path))
    }

    func testInterruptedLayerCleanupLeavesUnmanagedQuarantineUntouched() throws {
        let snapshotsRoot = VMSnapshotManager.snapshotsRootURL(vmRootPath: temporaryRoot)
        let quarantine = snapshotsRoot.appendingPathComponent(".layer-cleanup-quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let unmanaged = quarantine.appendingPathComponent("notes.txt")
        try Data("do not delete".utf8).write(to: unmanaged)
        let journal = #"{"phase":"committed","layerNames":["notes.txt"]}"#
        let journalURL = snapshotsRoot.appendingPathComponent(".layer-cleanup-transaction.json")
        try Data(journal.utf8).write(to: journalURL)

        if case .success = VMSnapshotManager.recoverInterruptedRestore(vmRootPath: temporaryRoot) {
            XCTFail("Recovery must fail closed when quarantine contains an unmanaged file")
        }

        XCTAssertEqual(try Data(contentsOf: unmanaged), Data("do not delete".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
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

    func testUnreadableRestoreJournalPreservesEveryOrdinaryRecoveryArtifact() throws {
        try write("current config", to: "config.json")
        let backup = temporaryRoot.appendingPathComponent(".restore-backup", isDirectory: true)
        let staging = temporaryRoot.appendingPathComponent(".restore-staging", isDirectory: true)
        let journal = temporaryRoot.appendingPathComponent(".restore-transaction.json")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("original config".utf8).write(to: backup.appendingPathComponent("config.json"))
        try Data("original disk".utf8).write(to: backup.appendingPathComponent("Disk.img"))
        try Data("staged config".utf8).write(to: staging.appendingPathComponent("config.json"))
        try Data("not a restore journal".utf8).write(to: journal)

        guard case let .failure(message) = VMSnapshotManager.recoverInterruptedRestore(
            vmRootPath: temporaryRoot
        ) else {
            return XCTFail("Recovery must fail closed when its journal exists but is unreadable")
        }

        XCTAssertTrue(message.contains("journal is unreadable"))
        XCTAssertEqual(try read("config.json"), "current config")
        XCTAssertEqual(
            try Data(contentsOf: backup.appendingPathComponent("config.json")),
            Data("original config".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: backup.appendingPathComponent("Disk.img")),
            Data("original disk".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: staging.appendingPathComponent("config.json")),
            Data("staged config".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: journal), Data("not a restore journal".utf8))
    }

    func testUnreadableLayeredRestoreJournalDoesNotGuessTheActiveASIFBranch() throws {
        let base = temporaryRoot.appendingPathComponent("Disk.asif")
        let snapshots = temporaryRoot.appendingPathComponent("Snapshots", isDirectory: true)
        let layers = snapshots.appendingPathComponent("Layers", isDirectory: true)
        let backup = temporaryRoot.appendingPathComponent(".restore-backup", isDirectory: true)
        let journal = temporaryRoot.appendingPathComponent(".restore-transaction.json")
        try FileManager.default.createDirectory(at: layers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("base".utf8).write(to: base)
        try Data("new layer".utf8).write(to: layers.appendingPathComponent("new.asif"))
        try write("current config", to: "config.json")
        let originalConfig = #"{"storageDevices":[{"type":"Block","imagePath":"Disk.asif","format":"asif"}]}"#
        try Data(originalConfig.utf8).write(to: backup.appendingPathComponent("config.json"))
        let currentState = #"{"currentSnapshotID":"new","activeDiskLayers":{"Disk.asif":["Snapshots/Layers/new.asif"]}}"#
        try Data(currentState.utf8).write(to: snapshots.appendingPathComponent("state.json"))
        let unknownPhaseJournal = #"{"snapshotID":"target","phase":"future"}"#
        try Data(unknownPhaseJournal.utf8).write(to: journal)

        guard case .failure = VMSnapshotManager.recoverInterruptedRestore(vmRootPath: temporaryRoot) else {
            return XCTFail("Layered recovery must not infer the previous branch without its journal")
        }

        XCTAssertEqual(try read("config.json"), "current config")
        XCTAssertEqual(try Data(contentsOf: base), Data("base".utf8))
        XCTAssertEqual(
            try Data(contentsOf: layers.appendingPathComponent("new.asif")),
            Data("new layer".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: snapshots.appendingPathComponent("state.json")),
            Data(currentState.utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: backup.appendingPathComponent("config.json")),
            Data(originalConfig.utf8)
        )
        XCTAssertEqual(try Data(contentsOf: journal), Data(unknownPhaseJournal.utf8))
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

    func testLayeredRestoreSurvivesProcessTerminationAtEveryCheckpoint() throws {
        for checkpoint in VMSnapshotRestoreCheckpoint.allCases {
            let root = temporaryRoot.appendingPathComponent("process-\(checkpoint.rawValue)", isDirectory: true)
            let fixture = try makeLayeredRestoreFixture(at: root)
            let layersURL = VMSnapshotManager.snapshotsRootURL(vmRootPath: root)
                .appendingPathComponent("Layers", isDirectory: true)
            let layersBeforeRestore = try Set(FileManager.default.contentsOfDirectory(atPath: layersURL.path))

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = [
                "xctest",
                "-XCTest",
                "VMSnapshotManagerTests/testLayeredRestoreCrashChild",
                Bundle(for: VMSnapshotManagerTests.self).bundleURL.path,
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["EZVM_SNAPSHOT_CRASH_ROOT"] = root.path
            environment["EZVM_SNAPSHOT_CRASH_ID"] = fixture.target.id
            environment["EZVM_SNAPSHOT_CRASH_CHECKPOINT"] = checkpoint.rawValue
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationReason, .exit, "Checkpoint: \(checkpoint)")
            XCTAssertEqual(process.terminationStatus, 86, "Checkpoint: \(checkpoint)")

            try unwrapSuccess(VMSnapshotManager.recoverInterruptedRestore(vmRootPath: root))

            let committed = checkpoint == .journalCommitted
            XCTAssertEqual(
                try String(contentsOf: root.appendingPathComponent("config.json"), encoding: .utf8),
                committed ? fixture.targetConfig : fixture.currentConfig,
                "Checkpoint: \(checkpoint)"
            )
            XCTAssertEqual(
                VMSnapshotManager.currentSnapshotID(vmRootPath: root),
                committed ? fixture.target.id : fixture.current.id,
                "Checkpoint: \(checkpoint)"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Disk.asif").path))
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

    func testLayeredRestoreCrashChild() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["EZVM_SNAPSHOT_CRASH_ROOT"],
              let snapshotID = environment["EZVM_SNAPSHOT_CRASH_ID"],
              let checkpointName = environment["EZVM_SNAPSHOT_CRASH_CHECKPOINT"] else {
            return
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let snapshot = try XCTUnwrap(
            VMSnapshotManager.listSnapshots(vmRootPath: root).first { $0.id == snapshotID }
        )
        let checkpoint = try XCTUnwrap(VMSnapshotRestoreCheckpoint(rawValue: checkpointName))
        _ = VMSnapshotManager.restoreSnapshot(
            vmRootPath: root,
            snapshot: snapshot,
            checkpointObserver: { reachedCheckpoint in
                if reachedCheckpoint == checkpoint {
                    _exit(86)
                }
            }
        )
        XCTFail("The crash checkpoint was not reached: \(checkpoint)")
    }

    func testProtectedSnapshotCannotBeDeletedUntilUnprotected() throws {
        try write("disk", to: "Disk.img")
        let snapshot = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(
                vmRootPath: temporaryRoot,
                name: "Keep me",
                isProtected: true
            )
        )
        XCTAssertTrue(snapshot.isProtected)
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

    func testConcurrentMutationInSameProcessIsRejectedWithoutChangingMetadata() throws {
        try write("configuration", to: "config.json")
        let existing = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "Existing")
        )
        let operationStarted = DispatchSemaphore(value: 0)
        let allowOperationToFinish = DispatchSemaphore(value: 0)
        let operationFinished = expectation(description: "snapshot operation finished")
        let callbackLock = NSLock()
        var didBlock = false

        DispatchQueue.global().async {
            _ = VMSnapshotManager.createSnapshot(
                vmRootPath: self.temporaryRoot,
                name: "Concurrent"
            ) { update in
                guard update.phase == .preparing else { return }
                callbackLock.lock()
                let shouldBlock = !didBlock
                didBlock = true
                callbackLock.unlock()
                if shouldBlock {
                    operationStarted.signal()
                    _ = allowOperationToFinish.wait(timeout: .now() + 5)
                }
            }
            operationFinished.fulfill()
        }

        XCTAssertEqual(operationStarted.wait(timeout: .now() + 2), .success)
        defer { allowOperationToFinish.signal() }
        guard case let .failure(message) = VMSnapshotManager.renameSnapshot(
            vmRootPath: temporaryRoot,
            snapshot: existing,
            newName: "Must not win"
        ) else {
            return XCTFail("A second in-process snapshot mutation was admitted")
        }
        XCTAssertTrue(message.contains("already changing"), message)
        XCTAssertEqual(
            VMSnapshotManager.listSnapshots(vmRootPath: temporaryRoot)
                .first(where: { $0.id == existing.id })?.name,
            "Existing"
        )
        allowOperationToFinish.signal()
        wait(for: [operationFinished], timeout: 5)
    }

    func testKernelLockRejectsMutationOwnedByAnotherProcessContext() throws {
        try write("configuration", to: "config.json")
        let lockURL = VMSnapshotManager.mutationLockURL(vmRootPath: temporaryRoot)
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        guard case let .failure(message) = VMSnapshotManager.createSnapshot(
            vmRootPath: temporaryRoot,
            name: "Must not start"
        ) else {
            return XCTFail("A mutation was admitted while the kernel lock was owned")
        }
        XCTAssertTrue(message.contains("Another EZVM process"), message)
        XCTAssertTrue(VMSnapshotManager.listSnapshots(vmRootPath: temporaryRoot).isEmpty)
    }

    func testSnapshotOperationLockIsNeverCapturedAsMachineState() throws {
        try write("configuration", to: "config.json")
        let snapshot = try unwrapSuccess(
            VMSnapshotManager.createSnapshot(vmRootPath: temporaryRoot, name: "No lock payload")
        )
        XCTAssertFalse(snapshot.fileManifest?.contains(where: {
            $0.relativePath == VMSnapshotManager.mutationLockURL(vmRootPath: temporaryRoot).lastPathComponent
        }) ?? true)
    }

    private func write(_ value: String, to relativePath: String) throws {
        try Data(value.utf8).write(to: temporaryRoot.appendingPathComponent(relativePath))
    }

    @discardableResult
    private func prepareLayeredASIFMachine(at root: URL) throws -> URL {
        let diskURL = root.appendingPathComponent("Disk.asif")
        try unwrapSuccess(VMDiskImageManager.create(format: .asif, at: diskURL, size: 64 * 1024 * 1024))
        let config = #"{"storageDevices":[{"type":"Block","size":67108864,"imagePath":"Disk.asif","format":"asif"}]}"#
        try Data(config.utf8).write(to: root.appendingPathComponent("config.json"))
        _ = try VMSnapshotManager.layeredDiskImage(baseURL: diskURL, vmRootPath: root)
        return diskURL
    }

    private func makeLayeredRestoreFixture(at root: URL) throws -> (
        target: VMSnapshotModel,
        current: VMSnapshotModel,
        targetConfig: String,
        currentConfig: String
    ) {
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
        return (target, current, targetConfig, currentConfig)
    }

    private func writeSnapshotMetadata(_ snapshot: VMSnapshotModel, at root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadataURL = VMSnapshotManager.snapshotsRootURL(vmRootPath: root)
            .appendingPathComponent(snapshot.id, isDirectory: true)
            .appendingPathComponent("snapshot.json")
        try encoder.encode(snapshot).write(to: metadataURL, options: .atomic)
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
