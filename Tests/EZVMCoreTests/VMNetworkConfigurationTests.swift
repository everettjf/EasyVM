import XCTest
import Virtualization
@testable import EZVMCore

#if arch(arm64)
final class VMNetworkConfigurationTests: XCTestCase {
    func testHostCapabilitiesRecognizeExpectedEntitlements() {
        XCTAssertEqual(
            VMHostCapability.virtualization.grantedEntitlementKey { $0 == "com.apple.security.virtualization" },
            "com.apple.security.virtualization"
        )
        XCTAssertEqual(
            VMHostCapability.vmnet.grantedEntitlementKey { $0 == "com.apple.developer.networking.vmnet" },
            "com.apple.developer.networking.vmnet"
        )
        XCTAssertEqual(
            VMHostCapability.accessoryAccess.grantedEntitlementKey { $0 == "com.apple.developer.accessory-access.usb" },
            "com.apple.developer.accessory-access.usb"
        )
    }

    func testHostCapabilitiesRecognizeLegacyVMNetEntitlement() {
        XCTAssertEqual(
            VMHostCapability.vmnet.grantedEntitlementKey { $0 == "com.apple.vm.networking" },
            "com.apple.vm.networking"
        )
    }

    func testHostCapabilitiesReportMissingEntitlements() {
        XCTAssertNil(VMHostCapability.virtualization.grantedEntitlementKey { _ in false })
        XCTAssertNil(VMHostCapability.vmnet.grantedEntitlementKey { _ in false })
        XCTAssertNil(VMHostCapability.accessoryAccess.grantedEntitlementKey { _ in false })
    }

    func testLegacyAdvancedNetworkDecodesAsNAT() throws {
        let data = Data(#"{"type":"Custom","networkIdentifier":"development","mtu":1500}"#.utf8)
        let model = try JSONDecoder().decode(VMModelFieldNetworkDevice.self, from: data)
        XCTAssertEqual(model.type, .NAT)
    }

    func testPlainNATBuildsNativeAttachment() {
        let model = VMModelFieldNetworkDevice.default()
        XCTAssertNil(model.validationError)
        switch model.createConfiguration() {
        case .success(let configuration):
            XCTAssertTrue(configuration.attachment is VZNATNetworkDeviceAttachment)
        case .failure(let error):
            XCTFail(error)
        }
    }
}
#endif
