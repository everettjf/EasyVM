import EasyVMCLIKit
import Foundation
import XCTest

final class EasyVMCLIKitTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testListIsSortedAndReportsValidMachineMetadata() throws {
        try makeMachine("Zulu.ezvm", name: "Zulu")
        try makeMachine("Alpha.ezvm", name: "Alpha")
        let (code, response) = EasyVMCLI().run(arguments: ["list", "--root", root.path])
        XCTAssertEqual(code, .success)
        guard case .array(let machines) = response.result else { return XCTFail("expected array") }
        XCTAssertEqual(machines.count, 2)
        guard case .object(let first) = machines[0] else { return XCTFail("expected object") }
        XCTAssertEqual(first["name"], .string("Alpha"))
        XCTAssertEqual(first["valid"], .bool(true))
        XCTAssertEqual(first["cpuCount"], .number(4))
    }

    func testValidateFailsDeterministicallyForMissingDisk() throws {
        let machine = try makeMachine("Broken.ezvm", name: "Broken", createDisk: false)
        let (code, response) = EasyVMCLI().run(arguments: ["validate", machine.path])
        XCTAssertEqual(code, .invalidMachine)
        XCTAssertEqual(response.error?.code, "invalid_machine")
        XCTAssertTrue(response.error?.message.contains("storage file is missing") == true)
    }

    func testInspectRejectsAmbiguousNamesAndAcceptsExactPath() throws {
        let first = try makeMachine("One/Same.ezvm", name: "Same")
        _ = try makeMachine("Two/Same.ezvm", name: "Same")
        let roots = [root.appendingPathComponent("One"), root.appendingPathComponent("Two")]
        let ambiguous = EasyVMCLI().run(arguments: ["inspect", "Same", "--root", roots[0].path, "--root", roots[1].path])
        XCTAssertEqual(ambiguous.0, .notFound)
        XCTAssertTrue(ambiguous.1.error?.message.contains("More than one") == true)
        XCTAssertEqual(EasyVMCLI().run(arguments: ["inspect", first.path]).0, .success)
    }

    func testSymlinkedMachineAndDiskAreNotTrusted() throws {
        let machine = try makeMachine("Real.ezvm", name: "Real")
        let alias = root.appendingPathComponent("Alias.ezvm")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: machine)
        XCTAssertEqual(EasyVMMachineInspector().discover(roots: [root]), [machine.standardizedFileURL])
        try FileManager.default.removeItem(at: machine.appendingPathComponent("Disk.img"))
        let outside = root.appendingPathComponent("outside.img")
        FileManager.default.createFile(atPath: outside.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: machine.appendingPathComponent("Disk.img"), withDestinationURL: outside)
        XCTAssertFalse(EasyVMMachineInspector().inspect(machine).valid)
    }

    func testOutputSchemaIsStableSortedJSONWithNewline() throws {
        let cli = EasyVMCLI()
        let data = try cli.encode(.init(command: "list", result: .array([])))
        XCTAssertEqual(data.last, 0x0a)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"command":"list","result":[],"schemaVersion":1,"success":true}"# + "\n")
    }

    func testArgumentsAndNotFoundUseDocumentedExitCodes() {
        XCTAssertEqual(EasyVMCLI().run(arguments: []).0, .invalidArguments)
        XCTAssertEqual(EasyVMCLI().run(arguments: ["wat"]).0, .invalidArguments)
        XCTAssertEqual(EasyVMCLI().run(arguments: ["inspect", "missing", "--root", root.path]).0, .notFound)
        XCTAssertEqual(EasyVMCLI().run(arguments: ["list", "unexpected"]).0, .invalidArguments)
        XCTAssertEqual(EasyVMCLI().run(arguments: ["start"]).0, .invalidArguments)
        XCTAssertEqual(EasyVMCLI().run(arguments: ["stop"]).0, .invalidArguments)
        XCTAssertEqual(EasyVMCLI().run(arguments: ["status"]).0, .invalidArguments)
        XCTAssertEqual(EasyVMCLI().run(arguments: ["start", "vm", "--timeout", "0"]).0, .invalidArguments)
    }

    @discardableResult
    private func makeMachine(_ relative: String, name: String, createDisk: Bool = true) throws -> URL {
        let machine = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "type": "linux", "name": name, "cpu": ["count": 4],
            "memory": ["size": 4_294_967_296 as UInt64],
            "storageDevices": [["type": "Block", "imagePath": "Disk.img", "size": 1024]],
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: machine.appendingPathComponent("config.json"))
        if createDisk { FileManager.default.createFile(atPath: machine.appendingPathComponent("Disk.img").path, contents: Data()) }
        return machine
    }
}
