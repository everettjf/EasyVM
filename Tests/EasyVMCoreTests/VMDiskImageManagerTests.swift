import Foundation
import XCTest
@testable import EasyVMCore

final class VMDiskImageManagerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyVMDiskTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func testRawCreationUsesRequestedLogicalSizeAndDoesNotOverwrite() throws {
        let url = temporaryRoot.appendingPathComponent("Disk.img")
        try unwrapSuccess(VMDiskImageManager.create(format: .raw, at: url, size: 4 * 1024 * 1024))

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertEqual(values.fileSize, 4 * 1024 * 1024)

        let marker = Data("preserve".utf8)
        try marker.write(to: url)
        try unwrapSuccess(VMDiskImageManager.create(format: .raw, at: url, size: 8 * 1024 * 1024))
        XCTAssertEqual(try Data(contentsOf: url), marker)
    }

    func testASIFCreationCommandUsesNoFilesystemAndExactByteSize() {
        let url = temporaryRoot.appendingPathComponent("Disk.asif")
        let command = VMDiskImageManager.creationCommand(format: .asif, url: url, size: 123_456)

        XCTAssertEqual(command?.executable, "/usr/sbin/diskutil")
        XCTAssertEqual(command?.arguments, [
            "image", "create", "blank",
            "--format", "ASIF",
            "--size", "123456",
            "--fs", "None",
            url.path,
        ])
    }

    func testRawToASIFConversionCommandKeepsSourceAndDestinationSeparate() {
        let source = temporaryRoot.appendingPathComponent("Disk.img")
        let destination = temporaryRoot.appendingPathComponent("Disk.asif")
        let command = VMDiskImageManager.conversionCommand(sourceURL: source, destinationURL: destination)

        XCTAssertEqual(command.arguments, [
            "image", "create", "from", "--format", "ASIF", source.path, destination.path,
        ])
    }

    private func unwrapSuccess(_ result: VMOSResultVoid, file: StaticString = #filePath, line: UInt = #line) throws {
        if case .failure(let message) = result {
            XCTFail(message, file: file, line: line)
        }
    }
}
