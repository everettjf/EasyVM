@testable import EZVMCLIKit
import CryptoKit
import Foundation
import XCTest

final class EZVMCLIKitTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testHostAppLocationResolvesHomebrewStyleCLISymlink() throws {
        let app = root.appendingPathComponent("EZVM.app/Contents")
        let helper = app.appendingPathComponent("Helpers/ezvm")
        let executable = app.appendingPathComponent("MacOS/EZVM")
        let bin = root.appendingPathComponent("bin/ezvm")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: helper.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try FileManager.default.createSymbolicLink(at: bin, withDestinationURL: helper)

        XCTAssertEqual(EZVMExecutableLocation.hostAppExecutable(for: bin.path), executable)
        XCTAssertEqual(
            EZVMExecutableLocation.hostAppExecutable(for: "ezvm", environment: ["PATH": bin.deletingLastPathComponent().path]),
            executable
        )
    }

    func testListIsSortedAndReportsValidMachineMetadata() throws {
        try makeMachine("Zulu.ezvm", name: "Zulu")
        try makeMachine("Alpha.ezvm", name: "Alpha")
        let (code, response) = EZVMCLI().run(arguments: ["list", "--root", root.path])
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
        let (code, response) = EZVMCLI().run(arguments: ["validate", machine.path])
        XCTAssertEqual(code, .invalidMachine)
        XCTAssertEqual(response.error?.code, "invalid_machine")
        XCTAssertTrue(response.error?.message.contains("storage file is missing") == true)
    }

    func testInspectRejectsAmbiguousNamesAndAcceptsExactPath() throws {
        let first = try makeMachine("One/Same.ezvm", name: "Same")
        _ = try makeMachine("Two/Same.ezvm", name: "Same")
        let roots = [root.appendingPathComponent("One"), root.appendingPathComponent("Two")]
        let ambiguous = EZVMCLI().run(arguments: ["inspect", "Same", "--root", roots[0].path, "--root", roots[1].path])
        XCTAssertEqual(ambiguous.0, .notFound)
        XCTAssertTrue(ambiguous.1.error?.message.contains("More than one") == true)
        XCTAssertEqual(EZVMCLI().run(arguments: ["inspect", first.path]).0, .success)
    }

    func testSymlinkedMachineAndDiskAreNotTrusted() throws {
        let machine = try makeMachine("Real.ezvm", name: "Real")
        let alias = root.appendingPathComponent("Alias.ezvm")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: machine)
        XCTAssertEqual(EZVMMachineInspector().discover(roots: [root]), [machine.standardizedFileURL])
        try FileManager.default.removeItem(at: machine.appendingPathComponent("Disk.img"))
        let outside = root.appendingPathComponent("outside.img")
        FileManager.default.createFile(atPath: outside.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: machine.appendingPathComponent("Disk.img"), withDestinationURL: outside)
        XCTAssertFalse(EZVMMachineInspector().inspect(machine).valid)
    }

    func testOutputSchemaIsStableSortedJSONWithNewline() throws {
        let cli = EZVMCLI()
        let data = try cli.encode(.init(command: "list", result: .array([])))
        XCTAssertEqual(data.last, 0x0a)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"command":"list","result":[],"schemaVersion":1,"success":true}"# + "\n")
    }

    func testArgumentsAndNotFoundUseDocumentedExitCodes() {
        XCTAssertEqual(EZVMCLI().run(arguments: []).0, .invalidArguments)
        XCTAssertEqual(EZVMCLI().run(arguments: ["wat"]).0, .invalidArguments)
        XCTAssertEqual(EZVMCLI().run(arguments: ["inspect", "missing", "--root", root.path]).0, .notFound)
        XCTAssertEqual(EZVMCLI().run(arguments: ["list", "unexpected"]).0, .invalidArguments)
        XCTAssertEqual(EZVMCLI().run(arguments: ["start"]).0, .invalidArguments)
        XCTAssertEqual(EZVMCLI().run(arguments: ["stop"]).0, .invalidArguments)
        XCTAssertEqual(EZVMCLI().run(arguments: ["status"]).0, .invalidArguments)
        XCTAssertEqual(EZVMCLI().run(arguments: ["start", "vm", "--timeout", "0"]).0, .invalidArguments)
        XCTAssertEqual(EZVMCLI().run(arguments: ["install-image"]).0, .invalidArguments)
    }

    func testPreinstalledImageManifestRejectsWrongIdentityArchitectureAndChecksum() throws {
        let disk = Data("test disk".utf8)
        let manifestURL = try makeManifest(disk: disk)
        XCTAssertNoThrow(try EZVMPreinstalledImageManifest.load(from: manifestURL, minimumDiskSize: 1))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        object["architecture"] = "x86_64"
        try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
        XCTAssertThrowsError(try EZVMPreinstalledImageManifest.load(from: manifestURL, minimumDiskSize: 1))

        object["architecture"] = "arm64"
        var diskObject = try XCTUnwrap(object["disk"] as? [String: Any])
        diskObject["sha256"] = "not-a-digest"
        object["disk"] = diskObject
        try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
        XCTAssertThrowsError(try EZVMPreinstalledImageManifest.load(from: manifestURL, minimumDiskSize: 1))
    }

    func testInstallImageVerifiesManifestAndInvokesHostApp() throws {
        let disk = Data("preinstalled image".utf8)
        let imageURL = root.appendingPathComponent("image.raw")
        try disk.write(to: imageURL)
        let manifestURL = try makeManifest(disk: disk)
        let destination = root.appendingPathComponent("Installed.ezvm")
        let fakeApp = try makeFakeApp(body: """
        destination=''
        while [ \"$#\" -gt 0 ]; do
          if [ \"$1\" = '--destination' ]; then destination=$2; shift 2; else shift; fi
        done
        mkdir -p \"$destination\"
        """)
        setenv("EZVM_APP_EXECUTABLE", fakeApp.path, 1)
        defer { unsetenv("EZVM_APP_EXECUTABLE") }

        let result = EZVMCLI(minimumPreinstalledDiskSize: 1).run(arguments: [
            "install-image", manifestURL.path, "--image", imageURL.path,
            "--destination", destination.path, "--name", "Test VM", "--timeout", "5",
        ])
        XCTAssertEqual(result.0, .success)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        guard case .object(let value) = result.1.result else { return XCTFail("expected result object") }
        XCTAssertEqual(value["productID"], .string("example.image"))
        XCTAssertEqual(value["name"], .string("Test VM"))
    }

    func testInstallImageTimeoutRemovesPartialDestination() throws {
        let disk = Data("interrupted image".utf8)
        let imageURL = root.appendingPathComponent("image.raw")
        try disk.write(to: imageURL)
        let manifestURL = try makeManifest(disk: disk)
        let destination = root.appendingPathComponent("Interrupted.ezvm")
        let fakeApp = try makeFakeApp(body: """
        destination=''
        staging_token=''
        while [ \"$#\" -gt 0 ]; do
          if [ \"$1\" = '--destination' ]; then destination=$2; shift 2
          elif [ \"$1\" = '--staging-token' ]; then staging_token=$2; shift 2
          else shift; fi
        done
        mkdir -p \"$destination\"
        mkdir -p \"$(dirname \"$destination\")/.$(basename \"$destination\").install-$staging_token\"
        sleep 10
        """)
        setenv("EZVM_APP_EXECUTABLE", fakeApp.path, 1)
        defer { unsetenv("EZVM_APP_EXECUTABLE") }

        let result = EZVMCLI(minimumPreinstalledDiskSize: 1).run(arguments: [
            "install-image", manifestURL.path, "--image", imageURL.path,
            "--destination", destination.path, "--timeout", "1",
        ])
        XCTAssertEqual(result.0, .unavailable)
        XCTAssertEqual(result.1.error?.code, "install_timeout")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".Interrupted.ezvm.install-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testInstallImageRejectsModifiedDiskBeforeLaunchingApp() throws {
        let original = Data("original image".utf8)
        let manifestURL = try makeManifest(disk: original)
        let imageURL = root.appendingPathComponent("image.raw")
        try Data("modified image".utf8).write(to: imageURL)
        let destination = root.appendingPathComponent("Rejected.ezvm")
        let result = EZVMCLI(minimumPreinstalledDiskSize: 1).run(arguments: [
            "install-image", manifestURL.path, "--image", imageURL.path, "--destination", destination.path,
        ])
        XCTAssertEqual(result.0, .invalidMachine)
        XCTAssertEqual(result.1.error?.code, "image_checksum_mismatch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
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

    private func makeManifest(disk: Data) throws -> URL {
        let digest = SHA256.hash(data: disk).map { String(format: "%02x", $0) }.joined()
        let value: [String: Any] = [
            "schemaVersion": 1,
            "kind": "io.github.everettjf.ezvm.preinstalled-image",
            "architecture": "arm64",
            "minimumEZVMVersion": "5.0.0",
            "product": ["id": "example.image", "name": "Example", "version": "1.0.0"],
            "disk": ["format": "raw", "virtualSize": disk.count, "sha256": digest],
            "virtualMachine": ["name": "Example VM", "remark": "Test image"],
        ]
        let url = root.appendingPathComponent("preinstalled-image.json")
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
        return url
    }

    private func makeFakeApp(body: String) throws -> URL {
        let url = root.appendingPathComponent("fake-ezvm-app")
        try ("#!/bin/sh\nset -eu\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
