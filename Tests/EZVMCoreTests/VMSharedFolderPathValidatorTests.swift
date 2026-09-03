import XCTest
@testable import EZVMCore

#if arch(arm64)
final class VMSharedFolderPathValidatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ezvm-shared-folder-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRecognizesAvailableDirectory() {
        XCTAssertEqual(VMSharedFolderPathValidator.status(for: root), .available)
    }

    func testRejectsRegularFile() throws {
        let file = root.appending(path: "document.txt")
        try Data("hello".utf8).write(to: file)
        XCTAssertEqual(VMSharedFolderPathValidator.status(for: file), .notDirectory)
    }

    func testReportsDirectoryRemovedAfterItWasShared() throws {
        let folder = root.appending(path: "Moved", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(VMSharedFolderPathValidator.status(for: folder), .available)
        try FileManager.default.removeItem(at: folder)
        XCTAssertEqual(VMSharedFolderPathValidator.status(for: folder), .missing)
    }

    func testRuntimeSharePlanKeepsAnEmptyShareEmpty() {
        XCTAssertEqual(VMSharedFolderRuntimePlan.uniquelyNamed([]), [])
    }

    func testRuntimeSharePlanDisambiguatesDuplicateNamesWithoutChangingPathsOrAccess() throws {
        let first = root.appending(path: "first/Projects", directoryHint: .isDirectory)
        let second = root.appending(path: "second/Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let entries = [
            VMSharedFolderRuntimeEntry(name: "Projects", path: first, readOnly: false),
            VMSharedFolderRuntimeEntry(name: "Projects", path: second, readOnly: true),
        ]

        XCTAssertEqual(VMSharedFolderRuntimePlan.uniquelyNamed(entries), [
            VMSharedFolderRuntimeEntry(name: "Projects", path: first, readOnly: false),
            VMSharedFolderRuntimeEntry(name: "Projects 2", path: second, readOnly: true),
        ])
    }
}
#endif
