import XCTest
import EZVMCore
@testable import EZVM_Omarchy

final class EZVMOmarchyTests: XCTestCase {
    func testDedicatedAppUsesOmarchyProductIdentity() throws {
        let profile = VMOmarchyProfile.production
        try profile.validate()
        XCTAssertEqual(profile.productID, "com.everettjf.ezvm.omarchy")
    }
}
