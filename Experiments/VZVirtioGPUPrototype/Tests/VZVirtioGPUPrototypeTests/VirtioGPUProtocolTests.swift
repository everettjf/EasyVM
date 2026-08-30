import Foundation
import Testing
@testable import VZVirtioGPUPrototype

@Test func rendererExecutorKeepsWorkOnOneThreadAndSupportsReentrancy() {
    let executor = RendererExecutor()
    defer { executor.stop() }

    let first = executor.sync { ObjectIdentifier(Thread.current) }
    let second = executor.sync { ObjectIdentifier(Thread.current) }
    let nested = executor.sync {
        executor.sync { ObjectIdentifier(Thread.current) }
    }

    #expect(first == second)
    #expect(second == nested)
}

@Test func displayInfoHasStandardWireLayout() throws {
    var request = Data()
    request.appendLittleEndian(VirtioGPU.Command.getDisplayInfo.rawValue)
    request.appendLittleEndian(UInt32(1))
    request.appendLittleEndian(UInt64(42))
    request.appendLittleEndian(UInt32(7))
    request.appendLittleEndian(UInt32(0))

    let header = try #require(VirtioGPU.Header(request))
    let response = VirtioGPU.displayInfoResponse(request: header, width: 1280, height: 720)

    #expect(response.count == 24 + 16 * 24)
    #expect(response.littleEndianUInt32(at: 0) == VirtioGPU.Response.okDisplayInfo.rawValue)
    #expect(response.littleEndianUInt64(at: 8) == 42)
    #expect(response.littleEndianUInt32(at: 32) == 1280)
    #expect(response.littleEndianUInt32(at: 36) == 720)
    #expect(response.littleEndianUInt32(at: 40) == 1)
}

@Test func responseHeaderPreservesFenceAndContext() throws {
    var request = Data()
    request.appendLittleEndian(VirtioGPU.Command.submit3D.rawValue)
    request.appendLittleEndian(UInt32(1))
    request.appendLittleEndian(UInt64.max - 7)
    request.appendLittleEndian(UInt32(99))
    request.appendLittleEndian(UInt32(0xdeadbeef))

    let header = try #require(VirtioGPU.Header(request))
    let response = VirtioGPU.responseHeader(.okNoData, request: header)
    #expect(response.count == 24)
    #expect(response.littleEndianUInt32(at: 4) == 1)
    #expect(response.littleEndianUInt64(at: 8) == UInt64.max - 7)
    #expect(response.littleEndianUInt32(at: 16) == 99)
    #expect(response.littleEndianUInt32(at: 20) == 0)
}

@Test func shortHeaderIsRejected() {
    #expect(VirtioGPU.Header(Data(repeating: 0, count: 23)) == nil)
}

@Test func littleEndianRoundTripAtUnalignedOffset() {
    var data = Data([0xaa])
    data.appendLittleEndian(UInt32(0x78563412))
    data.appendLittleEndian(UInt64(0xfedcba9876543210))
    #expect(data.littleEndianUInt32(at: 1) == 0x78563412)
    #expect(data.littleEndianUInt64(at: 5) == 0xfedcba9876543210)
}

@Test func virglCommandValuesMatchVirtioGPUABI() {
    #expect(VirtioGPU.Command.contextCreate.rawValue == 0x0200)
    #expect(VirtioGPU.Command.resourceCreate3D.rawValue == 0x0204)
    #expect(VirtioGPU.Command.transferToHost3D.rawValue == 0x0205)
    #expect(VirtioGPU.Command.transferFromHost3D.rawValue == 0x0206)
    #expect(VirtioGPU.Command.submit3D.rawValue == 0x0207)
    #expect(VirtioGPU.Response.okCapset.rawValue == 0x1103)
}
