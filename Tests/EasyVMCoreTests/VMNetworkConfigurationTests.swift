import XCTest
import Virtualization
@testable import EasyVMCore

#if arch(arm64)
final class VMNetworkConfigurationTests: XCTestCase {
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
