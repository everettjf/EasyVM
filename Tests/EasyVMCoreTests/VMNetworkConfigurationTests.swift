import Foundation
import XCTest
@testable import EasyVMCore

final class VMNetworkConfigurationTests: XCTestCase {
    func testLegacyNATConfigurationDecodesWithSafeDefaults() throws {
        let data = Data(#"{"type":"NAT"}"#.utf8)
        let model = try JSONDecoder().decode(VMModelFieldNetworkDevice.self, from: data)

        XCTAssertEqual(model.type, .NAT)
        XCTAssertEqual(model.networkIdentifier, "easyvm-default")
        XCTAssertEqual(model.subnetAddress, "192.168.105.0")
        XCTAssertEqual(model.subnetMask, "255.255.255.0")
        XCTAssertEqual(model.mtu, 1500)
        XCTAssertTrue(model.portForwardingRules.isEmpty)
    }

    func testCustomNetworkAndPortRulesRoundTrip() throws {
        let rule = VMPortForwardingRule(
            transport: .tcp,
            hostPort: 2222,
            guestAddress: "192.168.105.2",
            guestPort: 22
        )
        let model = VMModelFieldNetworkDevice(
            type: .Custom,
            networkIdentifier: "development",
            externalInterfaceName: "en0",
            subnetAddress: "192.168.105.0",
            subnetMask: "255.255.255.0",
            mtu: 1400,
            portForwardingRules: [rule]
        )

        let encoded = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(VMModelFieldNetworkDevice.self, from: encoded)

        XCTAssertEqual(decoded.type, .Custom)
        XCTAssertEqual(decoded.networkIdentifier, "development")
        XCTAssertEqual(decoded.externalInterfaceName, "en0")
        XCTAssertEqual(decoded.mtu, 1400)
        XCTAssertEqual(decoded.portForwardingRules, [rule])
    }

    func testPlainNATBuildsNativeAttachment() throws {
        let model = VMModelFieldNetworkDevice.default()
        guard case let .success(configuration) = model.createConfiguration() else {
            return XCTFail("Expected NAT configuration to succeed")
        }
        XCTAssertNotNil(configuration.attachment)
    }

    func testPortForwardingRejectsInvalidAndDuplicateRules() {
        let zeroPort = VMPortForwardingRule(hostPort: 0, guestAddress: "192.168.105.2", guestPort: 22)
        XCTAssertNotNil(VMModelFieldNetworkDevice(type: .NAT, portForwardingRules: [zeroPort]).validationError)

        let first = VMPortForwardingRule(hostPort: 2222, guestAddress: "192.168.105.2", guestPort: 22)
        let duplicate = VMPortForwardingRule(hostPort: 2222, guestAddress: "192.168.105.3", guestPort: 22)
        XCTAssertEqual(
            VMModelFieldNetworkDevice(type: .NAT, portForwardingRules: [first, duplicate]).validationError,
            "Host TCP port 2222 is forwarded more than once."
        )
    }

    func testCustomNetworkValidatesSubnetAndMTU() {
        XCTAssertNotNil(VMModelFieldNetworkDevice(type: .Custom, subnetAddress: "192.168.105.7").validationError)
        XCTAssertNotNil(VMModelFieldNetworkDevice(type: .Custom, subnetMask: "255.0.255.0").validationError)
        XCTAssertNotNil(VMModelFieldNetworkDevice(type: .Custom, mtu: 500).validationError)

        let outside = VMPortForwardingRule(hostPort: 2222, guestAddress: "10.0.0.2", guestPort: 22)
        XCTAssertNotNil(VMModelFieldNetworkDevice(type: .Custom, portForwardingRules: [outside]).validationError)
    }
}
