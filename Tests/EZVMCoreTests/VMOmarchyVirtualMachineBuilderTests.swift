import Virtualization
import XCTest
@testable import EZVMCore

final class VMOmarchyVirtualMachineBuilderTests: XCTestCase {
    func testBuilderCreatesValidatedFixedLinuxConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "VMOmarchyBuilderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        try FileManager.default.createDirectory(at: layout.workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.boot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.enrollment, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.shared, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: layout.disk.path, contents: Data(count: 1_048_576)))
        try VZGenericMachineIdentifier().dataRepresentation.write(to: layout.machineIdentifier)

        let gib = UInt64(1_024 * 1_024 * 1_024)
        let configuration = try VMOmarchyVirtualMachineBuilder.makeUnvalidatedConfigurationForTesting(
            layout: layout,
            profile: .production,
            hostMemoryBytes: 32 * gib,
            activeProcessorCount: 10
        )

        XCTAssertEqual(configuration.cpuCount, 6)
        XCTAssertEqual(configuration.memorySize, 16 * gib)
        XCTAssertEqual(configuration.storageDevices.count, 1)
        XCTAssertEqual(configuration.graphicsDevices.count, 1)
        XCTAssertEqual(configuration.socketDevices.count, 1)
        XCTAssertEqual(configuration.directorySharingDevices.count, 2)
        XCTAssertEqual(
            (configuration.directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration)?.tag,
            "ezvm-agent"
        )
        XCTAssertEqual(
            (configuration.directorySharingDevices.last as? VZVirtioFileSystemDeviceConfiguration)?.tag,
            "ezvm_shared"
        )
        XCTAssertEqual(configuration.consoleDevices.count, 1)
        let console = try XCTUnwrap(configuration.consoleDevices.first as? VZVirtioConsoleDeviceConfiguration)
        let clipboard = try XCTUnwrap(console.ports[0]?.attachment as? VZSpiceAgentPortAttachment)
        XCTAssertTrue(clipboard.sharesClipboard)
        XCTAssertEqual(configuration.audioDevices.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.efiVariableStore.path))
    }
}
