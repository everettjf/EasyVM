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
}
#endif
