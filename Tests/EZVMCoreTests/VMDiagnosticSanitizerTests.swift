import XCTest
@testable import EZVMCore

final class VMDiagnosticSanitizerTests: XCTestCase {
    func testConfigurationKeepsNetworkDiagnosticsButRemovesPrivateMetadata() throws {
        let input = #"""
        {
          "name": "Client Project",
          "remark": "confidential",
          "storageDevices": [{"type":"Block","imagePath":"/Users/alice/Secret/Disk.asif","format":"asif"}],
          "directorySharingDevices": [{"tag":"ezvm_shared","items":[{"name":"Taxes","path":"file:///Users/alice/Taxes","readOnly":true}]}],
          "networkDevices": [{
            "id":"919D9852-C523-4FA6-A55E-B6C8ADCDFF3A",
            "type":"VMNetShared",
            "networkIdentifier":"private-lab",
            "externalInterface":"en0",
            "ipv4Subnet":"192.168.73.0",
            "ipv4SubnetMask":"255.255.255.0",
            "portForwardingRules":[{"transport":"tcp","externalPort":2222,"internalAddress":"192.168.73.2","internalPort":22}]
          }]
        }
        """#
        let output = try XCTUnwrap(VMDiagnosticSanitizer.sanitizedConfiguration(data: Data(input.utf8)))

        for privateValue in ["Client Project", "confidential", "alice", "Taxes", "919D9852", "private-lab"] {
            XCTAssertFalse(output.contains(privateValue))
        }
        for diagnosticValue in ["VMNetShared", "en0", "192.168.73.0", "2222", "<configured>"] {
            XCTAssertTrue(output.contains(diagnosticValue))
        }
    }

    func testConfigurationRedactsUnexpectedSecretAndAbsolutePathFields() throws {
        let input = #"{"futureCredential":"abc","futureURL":"/Users/alice/private","ordinary":"safe"}"#
        let output = try XCTUnwrap(VMDiagnosticSanitizer.sanitizedConfiguration(data: Data(input.utf8)))

        XCTAssertFalse(output.contains("abc"))
        XCTAssertFalse(output.contains("alice"))
        XCTAssertTrue(output.contains("<redacted>"))
        XCTAssertTrue(output.contains("<redacted-path>"))
        XCTAssertTrue(output.contains("safe"))
    }

    func testLogSanitizerReplacesLongestMachinePathBeforeHomeDirectory() {
        let output = VMDiagnosticSanitizer.sanitizedLogMessage(
            "Failed /Users/alice/VMs/Test.ezvm/Disk.asif under /Users/alice/Desktop",
            homeDirectory: "/Users/alice",
            machinePaths: ["/Users/alice/VMs/Test.ezvm"]
        )

        XCTAssertEqual(output, "Failed <vm-bundle>/Disk.asif under <home>/Desktop")
    }

    func testMalformedConfigurationIsNotExported() {
        XCTAssertNil(VMDiagnosticSanitizer.sanitizedConfiguration(data: Data("not json".utf8)))
    }

    func testErrorIdentifierDoesNotIncludePotentiallySensitiveDescription() {
        let error = NSError(
            domain: "AccessoryError",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Serial 1234 at /Users/alice"]
        )

        XCTAssertEqual(
            VMDiagnosticSanitizer.errorIdentifier(error),
            "domain=AccessoryError code=42"
        )
    }
}
