import XCTest
@testable import EasyVMCore

final class VMPortabilityManagerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyVMPortability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCloneChangesIdentityAndNameAndDropsUnsafeRuntimeHistory() throws {
        let source = try makeMachine(name: "Source")
        try Data("old state".utf8).write(to: source.appendingPathComponent("MachineState.vzvmsave"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Snapshots"), withIntermediateDirectories: true)
        try Data("history".utf8).write(to: source.appendingPathComponent("Snapshots/item"))
        let destination = root.appendingPathComponent("Clone.ezvm")
        let newID = Data("new identifier".utf8)

        try unwrap(VMPortabilityManager.clone(
            sourceURL: source, destinationURL: destination, newName: "Clone", machineIdentifierData: newID
        ))

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("MachineIdentifier")), newID)
        let config = try json(destination.appendingPathComponent("config.json"))
        XCTAssertEqual(config["name"] as? String, "Clone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("MachineState.vzvmsave").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Snapshots").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("MachineIdentifier")), Data("source identifier".utf8))
    }

    func testCloneRefusesExistingDestinationWithoutChangingIt() throws {
        let source = try makeMachine(name: "Source")
        let destination = root.appendingPathComponent("Existing.ezvm")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: destination.appendingPathComponent("marker"))
        if case .success = VMPortabilityManager.clone(
            sourceURL: source, destinationURL: destination, newName: "Clone", machineIdentifierData: Data()
        ) { XCTFail("Expected destination conflict") }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("marker")), Data("keep".utf8))
    }

    func testFailedCloneRollsBackPartialDestinationAndKeepsSource() throws {
        let source = try makeMachine(name: "Source")
        let destination = root.appendingPathComponent("Failed.ezvm")
        if case .success = VMPortabilityManager.clone(
            sourceURL: source,
            destinationURL: destination,
            newName: "   ",
            machineIdentifierData: Data("new".utf8)
        ) { XCTFail("Expected invalid-name failure") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try json(source.appendingPathComponent("config.json"))["name"] as? String, "Source")
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("Disk.img")), Data("disk data".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix("partial") })
    }

    func testNestedDestinationsAreRejected() throws {
        let source = try makeMachine(name: "Source")
        let nestedClone = source.appendingPathComponent("Clone.ezvm")
        if case .success = VMPortabilityManager.clone(
            sourceURL: source, destinationURL: nestedClone, newName: "Clone", machineIdentifierData: Data("new".utf8)
        ) { XCTFail("Expected nested clone rejection") }
        let nestedExport = source.appendingPathComponent("Export.easyvmexport")
        if case .success = VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: nestedExport) {
            XCTFail("Expected nested export rejection")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: nestedClone.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nestedExport.path))
    }

    func testExportValidateAndImportRoundTrip() throws {
        let source = try makeMachine(name: "Portable")
        let export = root.appendingPathComponent("Portable.easyvmexport")
        try unwrap(VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: export))
        let manifest = try unwrap(VMPortabilityManager.validateExport(at: export))
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(Set(manifest.files.map(\.relativePath)), ["Disk.img", "MachineIdentifier", "config.json"])

        let imported = root.appendingPathComponent("Imported.ezvm")
        let importedID = Data("imported identifier".utf8)
        try unwrap(VMPortabilityManager.importMachine(
            exportURL: export, destinationURL: imported,
            identityMode: .copy(machineIdentifierData: importedID, name: "Imported")
        ))
        XCTAssertEqual(try Data(contentsOf: imported.appendingPathComponent("Disk.img")), Data("disk data".utf8))
        XCTAssertEqual(try Data(contentsOf: imported.appendingPathComponent("MachineIdentifier")), importedID)
        XCTAssertEqual(try json(imported.appendingPathComponent("config.json"))["name"] as? String, "Imported")
    }

    func testValidationDetectsSameSizeCorruptionAndImportCreatesNothing() throws {
        let source = try makeMachine(name: "Portable")
        let export = root.appendingPathComponent("Portable.easyvmexport")
        try unwrap(VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: export))
        let disk = export.appendingPathComponent("Machine.ezvm/Disk.img")
        try Data("DIsk data".utf8).write(to: disk)
        if case .success = VMPortabilityManager.validateExport(at: export) { XCTFail("Expected checksum failure") }
        let destination = root.appendingPathComponent("Rejected.ezvm")
        if case .success = VMPortabilityManager.importMachine(
            exportURL: export, destinationURL: destination,
            identityMode: .copy(machineIdentifierData: Data("new".utf8), name: "Rejected")
        ) {
            XCTFail("Expected import failure")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRestoreImportPreservesIdentityNameAndHistory() throws {
        let source = try makeMachine(name: "Backup")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Snapshots"), withIntermediateDirectories: true)
        try Data("history".utf8).write(to: source.appendingPathComponent("Snapshots/item"))
        let export = root.appendingPathComponent("Backup.easyvmexport")
        try unwrap(VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: export))
        let restored = root.appendingPathComponent("Restored.ezvm")

        try unwrap(VMPortabilityManager.importMachine(exportURL: export, destinationURL: restored, identityMode: .restore))

        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("MachineIdentifier")), Data("source identifier".utf8))
        XCTAssertEqual(try json(restored.appendingPathComponent("config.json"))["name"] as? String, "Backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.appendingPathComponent("Snapshots/item").path))
    }

    func testCopyImportDropsRuntimeHistoryAndRepeatedImportsUseDistinctIdentities() throws {
        let source = try makeMachine(name: "Portable")
        try Data("state".utf8).write(to: source.appendingPathComponent("MachineState.vzvmsave"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Snapshots"), withIntermediateDirectories: true)
        let export = root.appendingPathComponent("Portable.easyvmexport")
        try unwrap(VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: export))
        let first = root.appendingPathComponent("First.ezvm")
        let second = root.appendingPathComponent("Second.ezvm")

        try unwrap(VMPortabilityManager.importMachine(
            exportURL: export, destinationURL: first,
            identityMode: .copy(machineIdentifierData: Data("first identity".utf8), name: "First")
        ))
        try unwrap(VMPortabilityManager.importMachine(
            exportURL: export, destinationURL: second,
            identityMode: .copy(machineIdentifierData: Data("second identity".utf8), name: "Second")
        ))

        XCTAssertNotEqual(try Data(contentsOf: first.appendingPathComponent("MachineIdentifier")),
                          try Data(contentsOf: second.appendingPathComponent("MachineIdentifier")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.appendingPathComponent("MachineState.vzvmsave").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.appendingPathComponent("Snapshots").path))
    }

    func testSparseEstimateUsesAllocatedBytesInsteadOfLogicalDiskSize() throws {
        let sparse = root.appendingPathComponent("Sparse.ezvm")
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: false)
        let disk = sparse.appendingPathComponent("Disk.img")
        XCTAssertTrue(FileManager.default.createFile(atPath: disk.path, contents: nil))
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: 8 * 1_024 * 1_024 * 1_024)
        try handle.close()

        let estimate = try VMPortabilityManager.estimate(
            sourceURL: sparse, destinationParent: root,
            availableBytes: Int64(256 * 1_024 * 1_024)
        )

        XCTAssertEqual(estimate.logicalBytes, 8 * 1_024 * 1_024 * 1_024)
        XCTAssertLessThan(estimate.allocatedBytes, 128 * 1_024 * 1_024)
        XCTAssertTrue(estimate.hasEnoughSpace)
    }

    func testValidationDetectsMissingAndUnexpectedFiles() throws {
        let source = try makeMachine(name: "Portable")
        let missingExport = root.appendingPathComponent("Missing.easyvmexport")
        try unwrap(VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: missingExport))
        try FileManager.default.removeItem(at: missingExport.appendingPathComponent("Machine.ezvm/Disk.img"))
        assertFailureContains(VMPortabilityManager.validateExport(at: missingExport), "missing")

        let extraExport = root.appendingPathComponent("Extra.easyvmexport")
        try unwrap(VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: extraExport))
        try Data("extra".utf8).write(to: extraExport.appendingPathComponent("Machine.ezvm/injected"))
        assertFailureContains(VMPortabilityManager.validateExport(at: extraExport), "unexpected")
    }

    func testSymbolicLinkIsRejectedAndPartialExportIsCleaned() throws {
        let source = try makeMachine(name: "Unsafe")
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/tmp")
        )
        let export = root.appendingPathComponent("Unsafe.easyvmexport")
        if case .success = VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: export) {
            XCTFail("Expected symlink rejection")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("Unsafe.easyvmexport") && $0.hasSuffix("partial") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    private func makeMachine(name: String) throws -> URL {
        let url = root.appendingPathComponent("\(name).ezvm")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let config: [String: Any] = ["name": name, "type": "linux"]
        try JSONSerialization.data(withJSONObject: config).write(to: url.appendingPathComponent("config.json"))
        try Data("disk data".utf8).write(to: url.appendingPathComponent("Disk.img"))
        try Data("source identifier".utf8).write(to: url.appendingPathComponent("MachineIdentifier"))
        return url
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func unwrap(_ result: VMOSResultVoid) throws {
        if case .failure(let error) = result { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
    }

    private func unwrap<T>(_ result: VMOSResult<T, String>) throws -> T {
        switch result {
        case .success(let value): return value
        case .failure(let error): throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
    }

    private func assertFailureContains<T>(_ result: VMOSResult<T, String>, _ text: String) {
        guard case .failure(let error) = result else { return XCTFail("Expected failure") }
        XCTAssertTrue(error.localizedCaseInsensitiveContains(text), error)
    }
}
