import XCTest
import Virtualization
@testable import EZVMCore

final class VMOmarchyWorkspaceTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "VMOmarchyWorkspaceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func testPreparePublishesCompleteWorkspaceAtomically() throws {
        let factory = temporaryRoot.appending(path: "factory.asif")
        try Data("factory".utf8).write(to: factory)
        let layout = VMOmarchyWorkspaceLayout(
            applicationSupportRoot: temporaryRoot.appending(path: "Application Support/EZVM Omarchy")
        )
        let manager = VMOmarchyWorkspaceManager(layout: layout)
        XCTAssertEqual(manager.inspect(), .notPrepared)
        let identifier = VZGenericMachineIdentifier().dataRepresentation

        try manager.prepare(
            factoryDisk: factory,
            configuration: try metadata(),
            machineIdentifier: identifier
        )

        XCTAssertEqual(manager.inspect(), .ready)
        XCTAssertEqual(try manager.metadata().factoryImageVersion, "test")
        XCTAssertEqual(try Data(contentsOf: layout.disk), Data("factory".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.snapshots.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.enrollment.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.shared.path))
        let enrollmentURL = layout.enrollment.appending(path: "config.json")
        let enrollment = try JSONDecoder().decode(
            VMGuestAgentEnrollment.self,
            from: Data(contentsOf: enrollmentURL)
        )
        XCTAssertEqual(
            enrollment.machineID,
            VMGuestAgentEnrollmentStore.machineID(machineIdentifierData: identifier)
        )
        XCTAssertEqual(enrollment.token.count, 32)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: enrollmentURL.path)[.posixPermissions] as? NSNumber,
            NSNumber(value: 0o600)
        )
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: layout.applicationSupportRoot.path)
            .contains(where: { $0.hasPrefix(".Workspace.preparing.") }))
    }

    func testRuntimeGuestIntegrationMetadataIsRecordedWithoutChangingFactoryIdentity() throws {
        let factory = temporaryRoot.appending(path: "factory.asif")
        try Data("factory".utf8).write(to: factory)
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: temporaryRoot.appending(path: "support"))
        let manager = VMOmarchyWorkspaceManager(layout: layout)
        try manager.prepare(
            factoryDisk: factory,
            configuration: try metadata(),
            machineIdentifier: VZGenericMachineIdentifier().dataRepresentation
        )

        try manager.recordGuestIntegration(
            omarchyRevision: "omarchy-2",
            agentVersion: "agent-3",
            capabilities: ["shutdown-v1", "clipboard-text-v1"]
        )

        let recorded = try manager.metadata()
        XCTAssertEqual(recorded.factoryImageVersion, "test")
        XCTAssertEqual(recorded.omarchyRevision, "omarchy-2")
        XCTAssertEqual(recorded.guestAgentVersion, "agent-3")
        XCTAssertEqual(recorded.guestCapabilities, ["clipboard-text-v1", "shutdown-v1"])
    }

    func testRuntimeGuestIntegrationMetadataRejectsUnboundedValues() throws {
        let factory = temporaryRoot.appending(path: "factory.asif")
        try Data("factory".utf8).write(to: factory)
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: temporaryRoot.appending(path: "support"))
        let manager = VMOmarchyWorkspaceManager(layout: layout)
        try manager.prepare(
            factoryDisk: factory,
            configuration: try metadata(),
            machineIdentifier: VZGenericMachineIdentifier().dataRepresentation
        )

        XCTAssertThrowsError(try manager.recordGuestIntegration(
            omarchyRevision: nil,
            agentVersion: String(repeating: "a", count: 129),
            capabilities: []
        ))
        XCTAssertNil(try manager.metadata().guestAgentVersion)
    }

    func testInvalidMetadataAndMachineIdentityRequireRecovery() throws {
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: temporaryRoot.appending(path: "support"))
        try FileManager.default.createDirectory(at: layout.workspace, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: layout.disk)
        try Data("not-json".utf8).write(to: layout.configuration)
        try VZGenericMachineIdentifier().dataRepresentation.write(to: layout.machineIdentifier)
        let manager = VMOmarchyWorkspaceManager(layout: layout)

        XCTAssertEqual(
            manager.inspect(),
            .recovering(reason: "The Omarchy workspace metadata is invalid or unsupported.")
        )
        try metadata().write(to: layout.configuration)
        try Data("invalid-identifier".utf8).write(to: layout.machineIdentifier)
        XCTAssertEqual(
            manager.inspect(),
            .recovering(reason: "The Omarchy machine identity is invalid.")
        )
    }

    func testVersionOneWorkspaceMigratesAfterProtectedSnapshot() throws {
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: temporaryRoot.appending(path: "support"))
        let manager = VMOmarchyWorkspaceManager(layout: layout)
        let factory = temporaryRoot.appending(path: "factory.asif")
        try Data("factory user data".utf8).write(to: factory)
        let legacy = VMOmarchyWorkspaceMetadata(
            schemaVersion: 1,
            productID: VMOmarchyProfile.production.productID,
            createdAt: Date(timeIntervalSince1970: 123),
            factoryImageVersion: "factory-1"
        )
        try manager.prepare(
            factoryDisk: factory,
            configuration: try JSONEncoder().encode(legacy),
            machineIdentifier: VZGenericMachineIdentifier().dataRepresentation
        )
        XCTAssertEqual(manager.inspect(), .migrationRequired(fromVersion: 1))

        try manager.migrateWorkspace()

        XCTAssertEqual(manager.inspect(), .ready)
        let migrated = try manager.metadata()
        XCTAssertEqual(migrated.schemaVersion, VMOmarchyWorkspaceMetadata.currentSchemaVersion)
        XCTAssertEqual(migrated.createdAt, legacy.createdAt)
        XCTAssertEqual(migrated.factoryImageVersion, "factory-1")
        XCTAssertEqual(try Data(contentsOf: layout.disk), Data("factory user data".utf8))
        let point = try XCTUnwrap(
            VMOmarchyRecoveryManager(workspaceManager: manager).recoveryPoints().first
        )
        XCTAssertEqual(point.name, "Before workspace migration 1 to 2")
        XCTAssertTrue(point.isProtected)
    }

    func testFailedWorkspaceMigrationKeepsOldMetadataAndProtectedSnapshot() throws {
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: temporaryRoot.appending(path: "support"))
        let manager = VMOmarchyWorkspaceManager(layout: layout)
        let factory = temporaryRoot.appending(path: "factory.asif")
        try Data("factory".utf8).write(to: factory)
        let legacyData = try JSONEncoder().encode(VMOmarchyWorkspaceMetadata(
            schemaVersion: 1,
            productID: VMOmarchyProfile.production.productID,
            createdAt: Date(timeIntervalSince1970: 123),
            factoryImageVersion: "factory-1"
        ))
        try manager.prepare(
            factoryDisk: factory,
            configuration: legacyData,
            machineIdentifier: VZGenericMachineIdentifier().dataRepresentation
        )

        XCTAssertThrowsError(try manager.migrateWorkspace(metadataWriter: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })) { error in
            guard case .migrationFailed = error as? VMOmarchyWorkspaceError else {
                return XCTFail("Expected migration failure, got \(error)")
            }
        }

        XCTAssertEqual(manager.inspect(), .migrationRequired(fromVersion: 1))
        XCTAssertEqual(try Data(contentsOf: layout.configuration), legacyData)
        let points = VMOmarchyRecoveryManager(workspaceManager: manager).recoveryPoints()
        XCTAssertEqual(points.count, 1)
        XCTAssertTrue(points[0].isProtected)
    }

    func testBrokenWorkspaceIsPreservedBeforeReinstall() throws {
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: temporaryRoot.appending(path: "support"))
        try FileManager.default.createDirectory(at: layout.workspace, withIntermediateDirectories: true)
        let userData = layout.workspace.appending(path: "user-data")
        try Data("keep me".utf8).write(to: userData)
        try FileManager.default.createDirectory(at: layout.enrollment, withIntermediateDirectories: true)
        try Data("old identity".utf8).write(to: layout.enrollment.appending(path: "config.json"))
        let manager = VMOmarchyWorkspaceManager(layout: layout)

        let preserved = try manager.quarantineBrokenWorkspace(now: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(manager.inspect(), .notPrepared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.workspace.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.enrollment.path))
        XCTAssertEqual(
            try Data(contentsOf: preserved.appending(path: "Workspace/user-data")),
            Data("keep me".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: preserved.appending(path: "Enrollment/config.json")),
            Data("old identity".utf8)
        )
        XCTAssertTrue(preserved.path.hasPrefix(layout.recovery.path + "/Recovery-1970-01-01T00-00-00Z"))

        let factory = temporaryRoot.appending(path: "factory.asif")
        try Data("factory".utf8).write(to: factory)
        try manager.prepare(
            factoryDisk: factory,
            configuration: try metadata(),
            machineIdentifier: VZGenericMachineIdentifier().dataRepresentation
        )
        XCTAssertEqual(manager.inspect(), .ready)
    }

    func testReadyWorkspaceCannotBeQuarantined() throws {
        let factory = temporaryRoot.appending(path: "factory.asif")
        try Data("factory".utf8).write(to: factory)
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: temporaryRoot.appending(path: "support"))
        let manager = VMOmarchyWorkspaceManager(layout: layout)
        try manager.prepare(
            factoryDisk: factory,
            configuration: try metadata(),
            machineIdentifier: VZGenericMachineIdentifier().dataRepresentation
        )

        XCTAssertThrowsError(try manager.quarantineBrokenWorkspace()) { error in
            XCTAssertEqual(error as? VMOmarchyWorkspaceError, .workspaceNotRecoverable)
        }
    }

    func testProtectedPreUpdatePointRestoresWorkspaceTransactionally() throws {
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: temporaryRoot.appending(path: "support"))
        let manager = VMOmarchyWorkspaceManager(layout: layout)
        let factory = temporaryRoot.appending(path: "factory.asif")
        try Data("original disk".utf8).write(to: factory)
        try manager.prepare(
            factoryDisk: factory,
            configuration: try metadata(),
            machineIdentifier: VZGenericMachineIdentifier().dataRepresentation
        )
        let recovery = VMOmarchyRecoveryManager(workspaceManager: manager)

        let point = try recovery.createProtectedPreUpdatePoint(targetVersion: "2.0")

        XCTAssertTrue(point.isProtected)
        XCTAssertEqual(point.name, "Before update to 2.0")
        XCTAssertEqual(recovery.recoveryPoints(), [point])
        try Data("updated but broken".utf8).write(to: layout.disk)

        try recovery.restore(id: point.id)

        XCTAssertEqual(try Data(contentsOf: layout.disk), Data("original disk".utf8))
        XCTAssertEqual(manager.inspect(), .ready)
        XCTAssertTrue(recovery.recoveryPoints().contains(where: { $0.id == point.id && $0.isProtected }))
    }

    func testPreUpdatePointLowSpaceFailureLeavesNoSnapshot() throws {
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: temporaryRoot.appending(path: "support"))
        let manager = VMOmarchyWorkspaceManager(layout: layout)
        let factory = temporaryRoot.appending(path: "factory.asif")
        try Data("factory".utf8).write(to: factory)
        try manager.prepare(
            factoryDisk: factory,
            configuration: try metadata(),
            machineIdentifier: VZGenericMachineIdentifier().dataRepresentation
        )
        let recovery = VMOmarchyRecoveryManager(workspaceManager: manager)

        XCTAssertThrowsError(try recovery.createProtectedPreUpdatePoint(
            targetVersion: "2.0",
            availableCapacityBytes: 0
        )) { error in
            guard case .operationFailed = error as? VMOmarchyRecoveryError else {
                return XCTFail("Expected a bounded recovery operation failure, got \(error)")
            }
        }
        XCTAssertTrue(recovery.recoveryPoints().isEmpty)
    }

    func testRestoreRejectsUnknownRecoveryPointWithoutChangingWorkspace() throws {
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: temporaryRoot.appending(path: "support"))
        let manager = VMOmarchyWorkspaceManager(layout: layout)
        let factory = temporaryRoot.appending(path: "factory.asif")
        let original = Data("factory".utf8)
        try original.write(to: factory)
        try manager.prepare(
            factoryDisk: factory,
            configuration: try metadata(),
            machineIdentifier: VZGenericMachineIdentifier().dataRepresentation
        )

        XCTAssertThrowsError(
            try VMOmarchyRecoveryManager(workspaceManager: manager).restore(id: UUID().uuidString)
        ) { error in
            XCTAssertEqual(error as? VMOmarchyRecoveryError, .recoveryPointNotFound)
        }
        XCTAssertEqual(try Data(contentsOf: layout.disk), original)
    }

    func testInterruptedRecoveryNeverFollowsSymlinkedWorkspace() throws {
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: temporaryRoot.appending(path: "support"))
        let outside = temporaryRoot.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let marker = outside.appending(path: ".restore-transaction.json")
        let original = Data("do not touch".utf8)
        try original.write(to: marker)
        try FileManager.default.createDirectory(at: layout.applicationSupportRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: layout.workspace, withDestinationURL: outside)

        XCTAssertThrowsError(
            try VMOmarchyRecoveryManager(
                workspaceManager: VMOmarchyWorkspaceManager(layout: layout)
            ).recoverInterruptedOperations()
        ) { error in
            XCTAssertEqual(error as? VMOmarchyRecoveryError, .workspaceNotReady)
        }
        XCTAssertEqual(try Data(contentsOf: marker), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [marker.lastPathComponent])
    }

    func testPrepareReusesExistingOmarchyEnrollment() throws {
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: temporaryRoot.appending(path: "support"))
        let identifier = Data("identifier".utf8)
        guard case .success(let first) = VMGuestAgentEnrollmentStore.loadOrCreate(
            machineIdentifierData: identifier,
            directoryURL: layout.enrollment
        ) else { return XCTFail("Could not create enrollment") }
        guard case .success(let second) = VMGuestAgentEnrollmentStore.loadOrCreate(
            machineIdentifierData: identifier,
            directoryURL: layout.enrollment
        ) else { return XCTFail("Could not reload enrollment") }

        XCTAssertEqual(first, second)
    }

    func testIncompleteWorkspaceRequiresRecoveryAndIsNeverOverwritten() throws {
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: temporaryRoot.appending(path: "support"))
        try FileManager.default.createDirectory(at: layout.workspace, withIntermediateDirectories: true)
        let manager = VMOmarchyWorkspaceManager(layout: layout)
        guard case .recovering = manager.inspect() else {
            return XCTFail("Expected recovery state")
        }

        let factory = temporaryRoot.appending(path: "factory.asif")
        try Data("factory".utf8).write(to: factory)
        XCTAssertThrowsError(try manager.prepare(
            factoryDisk: factory,
            configuration: Data(),
            machineIdentifier: Data()
        )) { error in
            XCTAssertEqual(error as? VMOmarchyWorkspaceError, .workspaceAlreadyExists)
        }
    }

    func testSymlinkedFactoryDiskIsRejected() throws {
        let actual = temporaryRoot.appending(path: "actual.asif")
        let link = temporaryRoot.appending(path: "factory.asif")
        try Data("factory".utf8).write(to: actual)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        let manager = VMOmarchyWorkspaceManager(
            layout: .init(applicationSupportRoot: temporaryRoot.appending(path: "support"))
        )
        XCTAssertThrowsError(try manager.prepare(
            factoryDisk: link,
            configuration: Data(),
            machineIdentifier: Data()
        )) { error in
            XCTAssertEqual(error as? VMOmarchyWorkspaceError, .invalidFactoryDisk)
        }
    }

    private func metadata() throws -> Data {
        try JSONEncoder().encode(VMOmarchyWorkspaceMetadata(
            productID: VMOmarchyProfile.production.productID,
            createdAt: Date(timeIntervalSince1970: 0),
            factoryImageVersion: "test"
        ))
    }
}
