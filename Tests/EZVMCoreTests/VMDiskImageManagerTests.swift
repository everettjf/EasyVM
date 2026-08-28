import Foundation
import XCTest
@testable import EZVMCore

final class VMDiskImageManagerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZVMDiskTests-\(UUID().uuidString)", isDirectory: true)
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
        if case .success = VMDiskImageManager.create(format: .raw, at: url, size: 8 * 1024 * 1024) {
            XCTFail("A mismatched existing disk must not be accepted")
        }
        XCTAssertEqual(try Data(contentsOf: url), marker)
    }

    func testRawCreationIsIdempotentOnlyForTheExactSize() throws {
        let url = temporaryRoot.appendingPathComponent("Disk.img")
        try unwrapSuccess(VMDiskImageManager.create(format: .raw, at: url, size: 4096))
        try unwrapSuccess(VMDiskImageManager.create(format: .raw, at: url, size: 4096))
        XCTAssertEqual(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, 4096)
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

    func testASIFHeaderValidationRejectsOtherExistingFiles() throws {
        let url = temporaryRoot.appendingPathComponent("Disk.asif")
        try Data("shdw-payload".utf8).write(to: url)
        XCTAssertTrue(VMDiskImageManager.existingASIFImageHasValidHeader(url: url))
        try Data("not-an-asif".utf8).write(to: url)
        XCTAssertFalse(VMDiskImageManager.existingASIFImageHasValidHeader(url: url))
    }

    func testExistingASIFCreationIsIdempotentForMatchingLogicalSize() throws {
        let url = temporaryRoot.appendingPathComponent("Disk.asif")
        let size: UInt64 = 64 * 1024 * 1024
        try unwrapSuccess(VMDiskImageManager.create(format: .asif, at: url, size: size))
        try unwrapSuccess(VMDiskImageManager.create(format: .asif, at: url, size: size))
    }

    func testRawToASIFConversionCommandKeepsSourceAndDestinationSeparate() {
        let source = temporaryRoot.appendingPathComponent("Disk.img")
        let destination = temporaryRoot.appendingPathComponent("Disk.asif")
        let command = VMDiskImageManager.conversionCommand(sourceURL: source, destinationURL: destination)

        XCTAssertEqual(command.arguments, [
            "image", "create", "from", "--format", "ASIF", source.path, destination.path,
        ])
    }

    func testFailedConversionRemovesPartialDestinationAndPreservesSource() throws {
        let source = temporaryRoot.appendingPathComponent("Disk.img")
        let destination = temporaryRoot.appendingPathComponent("Disk.asif")
        let sourceData = Data("source".utf8)
        try sourceData.write(to: source)

        let result = VMDiskImageManager.convertRawToASIF(
            sourceURL: source,
            destinationURL: destination
        ) { _ in
            try? Data("partial".utf8).write(to: destination)
            return .failure("simulated diskutil failure")
        }

        if case .success = result { XCTFail("Expected conversion failure") }
        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func unwrapSuccess(_ result: VMOSResultVoid, file: StaticString = #filePath, line: UInt = #line) throws {
        if case .failure(let message) = result {
            XCTFail(message, file: file, line: line)
        }
    }
}
