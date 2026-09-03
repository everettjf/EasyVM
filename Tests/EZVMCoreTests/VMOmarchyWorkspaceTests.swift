import XCTest
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

        try manager.prepare(
            factoryDisk: factory,
            configuration: Data("configuration".utf8),
            machineIdentifier: Data("identifier".utf8)
        )

        XCTAssertEqual(manager.inspect(), .ready)
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
            VMGuestAgentEnrollmentStore.machineID(machineIdentifierData: Data("identifier".utf8))
        )
        XCTAssertEqual(enrollment.token.count, 32)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: enrollmentURL.path)[.posixPermissions] as? NSNumber,
            NSNumber(value: 0o600)
        )
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: layout.applicationSupportRoot.path)
            .contains(where: { $0.hasPrefix(".Workspace.preparing.") }))
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
}
