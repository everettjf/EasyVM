import Foundation
import XCTest
@testable import EasyVMCore

final class VMUSBDeviceDescriptorTests: XCTestCase {
    func testParsesLittleEndianDeviceDescriptor() throws {
        let bytes: [UInt8] = [
            18, 1, 0, 3, 8, 6, 80, 64,
            0x34, 0x12, 0xCD, 0xAB, 0, 1, 1, 2, 3, 1,
        ]
        let descriptor = try XCTUnwrap(VMUSBDeviceDescriptor(data: Data(bytes)))

        XCTAssertEqual(descriptor.vendorID, 0x1234)
        XCTAssertEqual(descriptor.productID, 0xABCD)
        XCTAssertEqual(descriptor.deviceClass, 8)
        XCTAssertEqual(descriptor.name, "USB Storage")
        XCTAssertEqual(descriptor.identifier, "1234:ABCD")
    }

    func testRejectsTruncatedOrWrongDescriptorType() {
        XCTAssertNil(VMUSBDeviceDescriptor(data: Data([11, 1] + Array(repeating: 0, count: 10))))
        XCTAssertNil(VMUSBDeviceDescriptor(data: Data([18, 2] + Array(repeating: 0, count: 16))))
    }

    func testUnknownClassUsesGenericName() throws {
        var bytes = [UInt8](repeating: 0, count: 18)
        bytes[0] = 18
        bytes[1] = 1
        bytes[4] = 255
        XCTAssertEqual(try XCTUnwrap(VMUSBDeviceDescriptor(data: Data(bytes))).name, "USB Accessory")
    }
}
