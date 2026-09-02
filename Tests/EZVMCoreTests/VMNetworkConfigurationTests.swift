import XCTest
import Virtualization
@testable import EZVMCore

#if arch(arm64)
final class VMNetworkConfigurationTests: XCTestCase {
    func testUSBPassthroughDisablesMachineStateWhileAttached() {
        XCTAssertFalse(VMUSBControllerSupport.canSaveMachineState(
            backendSupportsSaveRestore: true,
            attachedAccessoryCount: 1
        ))
        XCTAssertTrue(VMUSBControllerSupport.canSaveMachineState(
            backendSupportsSaveRestore: true,
            attachedAccessoryCount: 0
        ))
        XCTAssertFalse(VMUSBControllerSupport.canSaveMachineState(
            backendSupportsSaveRestore: false,
            attachedAccessoryCount: 0
        ))
    }

    func testUSBDescriptorParsesVendorAndProductInLittleEndianOrder() {
        let descriptor = Data([18, 1, 0, 2, 0, 0, 0, 64, 0x34, 0x12, 0xCD, 0xAB])
        XCTAssertEqual(
            VMUSBDeviceDescriptorSummary.parse(registryID: 42, descriptor: descriptor),
            VMUSBDeviceDescriptorSummary(registryID: 42, vendorID: 0x1234, productID: 0xABCD)
        )
    }

    func testUSBDescriptorRejectsTruncatedOrWrongDescriptorType() {
        XCTAssertNil(VMUSBDeviceDescriptorSummary.parse(registryID: 1, descriptor: Data([11, 1])))
        XCTAssertNil(VMUSBDeviceDescriptorSummary.parse(
            registryID: 1,
            descriptor: Data([18, 2, 0, 2, 0, 0, 0, 64, 1, 0, 2, 0])
        ))
    }

    func testUSBControllerSupportAddsExactlyOneController() {
        let configuration = VZVirtualMachineConfiguration()
        VMUSBControllerSupport.addEmptyXHCIController(to: configuration)
        VMUSBControllerSupport.addEmptyXHCIController(to: configuration)
        XCTAssertEqual(configuration.usbControllers.count, 1)
        XCTAssertTrue(configuration.usbControllers[0] is VZXHCIControllerConfiguration)
        XCTAssertTrue(configuration.usbControllers[0].usbDevices.isEmpty)
    }

    func testUSBControllerDisconnectMatchesTheExactAttachedDevice() {
        final class Device {}
        let disconnected = Device()
        let other = Device()
        let devices: [UInt64: Device] = [17: disconnected, 42: other]

        XCTAssertEqual(
            VMUSBControllerSupport.registryID(forDisconnected: disconnected, in: devices),
            17
        )
        XCTAssertNil(
            VMUSBControllerSupport.registryID(forDisconnected: Device(), in: devices)
        )
    }

    func testVirtualMachineLabelTrimsWhitespaceAndAppliesToConfiguration() {
        let configuration = VZVirtualMachineConfiguration()
        VMConfigurationIdentity.apply(machineName: "  Development VM\n", to: configuration)

        XCTAssertEqual(configuration.label, "Development VM")
    }

    func testVirtualMachineLabelRejectsBlankNames() {
        XCTAssertNil(VMConfigurationIdentity.label(for: " \n\t "))
    }

    func testVirtualMachineLabelIsLimitedToSixtyFourCharacters() {
        let label = VMConfigurationIdentity.label(for: String(repeating: "虚", count: 80))

        XCTAssertEqual(label?.count, VMConfigurationIdentity.maximumLabelLength)
        XCTAssertEqual(label, String(repeating: "虚", count: 64))
    }

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

    func testVMNetConfigurationRoundTripsWithoutChangingNATDefault() throws {
        let rule = VMModelFieldNetworkDevice.PortForwardingRule(
            transport: .tcp,
            externalPort: 2222,
            internalAddress: "192.168.73.10",
            internalPort: 22
        )
        let model = VMModelFieldNetworkDevice(
            type: .VMNetShared,
            networkIdentifier: "development",
            ipv4Subnet: "192.168.73.0",
            ipv4SubnetMask: "255.255.255.0",
            externalInterface: "en0",
            mtu: 1500,
            portForwardingRules: [rule]
        )

        let decoded = try JSONDecoder().decode(
            VMModelFieldNetworkDevice.self,
            from: JSONEncoder().encode(model)
        )
        XCTAssertEqual(decoded.type, .VMNetShared)
        XCTAssertEqual(decoded.networkIdentifier, "development")
        XCTAssertEqual(decoded.ipv4Subnet, "192.168.73.0")
        XCTAssertEqual(decoded.ipv4SubnetMask, "255.255.255.0")
        XCTAssertEqual(decoded.externalInterface, "en0")
        XCTAssertEqual(decoded.mtu, 1500)
        XCTAssertEqual(decoded.portForwardingRules, [rule])
        XCTAssertEqual(VMModelFieldNetworkDevice.default().type, .NAT)
    }

    func testVMNetStructuralValidationRejectsUnsafeConfigurations() {
        XCTAssertNotNil(VMModelFieldNetworkDevice(
            type: .VMNetShared,
            ipv4Subnet: "192.168.73.0"
        ).validationError(vmnetEntitlementGranted: true))
        XCTAssertNotNil(VMModelFieldNetworkDevice(
            type: .VMNetHost,
            externalInterface: "en0"
        ).validationError(vmnetEntitlementGranted: true))
        XCTAssertNotNil(VMModelFieldNetworkDevice(
            type: .VMNetShared,
            mtu: 200
        ).validationError(vmnetEntitlementGranted: true))

        let first = VMModelFieldNetworkDevice.PortForwardingRule(
            transport: .tcp,
            externalPort: 2222,
            internalAddress: "192.168.73.10",
            internalPort: 22
        )
        let duplicate = VMModelFieldNetworkDevice.PortForwardingRule(
            transport: .tcp,
            externalPort: 2222,
            internalAddress: "192.168.73.11",
            internalPort: 22
        )
        XCTAssertNotNil(VMModelFieldNetworkDevice(
            type: .VMNetShared,
            portForwardingRules: [first, duplicate]
        ).validationError(vmnetEntitlementGranted: true))
    }

    func testVMNetStructuralValidationAcceptsSharedAndHostOnlyModes() {
        let shared = VMModelFieldNetworkDevice(
            type: .VMNetShared,
            networkIdentifier: "shared-lab",
            ipv4Subnet: "192.168.73.0",
            ipv4SubnetMask: "255.255.255.0",
            mtu: 1500
        )
        let host = VMModelFieldNetworkDevice(
            type: .VMNetHost,
            networkIdentifier: "host-lab"
        )
        XCTAssertNil(shared.validationError(vmnetEntitlementGranted: true))
        XCTAssertNil(host.validationError(vmnetEntitlementGranted: true))
        XCTAssertNotNil(shared.validationError(vmnetEntitlementGranted: false))
    }
}
#endif
