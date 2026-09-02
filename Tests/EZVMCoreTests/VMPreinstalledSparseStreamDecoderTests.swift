import XCTest
@testable import EZVMCore

#if arch(arm64)
final class VMPreinstalledSparseStreamDecoderTests: XCTestCase {
    func testCancellationStopsDecodeAndCanBeCleanedUp() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancelled-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: output) }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let payload = Data("EZVM-SPARSE-1\n16\n0 8\n12345678\nEND\n".utf8)
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancelled-\(UUID().uuidString).stream")
        defer { try? FileManager.default.removeItem(at: inputURL) }
        try payload.write(to: inputURL)
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }

        XCTAssertThrowsError(
            try VMPreinstalledSparseStreamDecoder.decode(
                from: input,
                to: output,
                expectedSize: 16,
                shouldCancel: { true }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }
    func testDecodesSparseExtentsAtExactOffsets() throws {
        let fixture = try makeFixture(stream: Data("EZVM-SPARSE-1\n16\n2 3\nabc\n10 2\nXY\nEND\n".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try VMPreinstalledSparseStreamDecoder.decode(from: fixture.input, to: fixture.output, expectedSize: 16)
        let result = try Data(contentsOf: fixture.output)

        XCTAssertEqual(result.count, 16)
        XCTAssertEqual(result.subdata(in: 2..<5), Data("abc".utf8))
        XCTAssertEqual(result.subdata(in: 10..<12), Data("XY".utf8))
        XCTAssertEqual(result[0], 0)
        XCTAssertEqual(result[15], 0)
    }

    func testRejectsExtentOutsideLogicalDisk() throws {
        let fixture = try makeFixture(stream: Data("EZVM-SPARSE-1\n16\n15 2\nab\nEND\n".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertThrowsError(try VMPreinstalledSparseStreamDecoder.decode(from: fixture.input, to: fixture.output, expectedSize: 16)) { error in
            XCTAssertEqual(error as? VMPreinstalledSparseStreamDecoder.DecodeError, .invalidExtent)
        }
    }

    func testRejectsTruncatedExtentPayload() throws {
        let fixture = try makeFixture(stream: Data("EZVM-SPARSE-1\n16\n2 4\nab".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertThrowsError(try VMPreinstalledSparseStreamDecoder.decode(from: fixture.input, to: fixture.output, expectedSize: 16)) { error in
            XCTAssertEqual(error as? VMPreinstalledSparseStreamDecoder.DecodeError, .truncated)
        }
    }

    private func makeFixture(stream: Data) throws -> (directory: URL, input: FileHandle, output: URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let inputURL = directory.appending(path: "input.sparse")
        let outputURL = directory.appending(path: "output.raw")
        try stream.write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        return (directory, try FileHandle(forReadingFrom: inputURL), outputURL)
    }
}
#endif
