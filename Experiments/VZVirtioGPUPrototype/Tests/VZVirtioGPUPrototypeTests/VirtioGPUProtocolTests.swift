import Foundation
import Testing
@testable import EZVMVirGLRuntime

@Test func runtimeDependencyResolverUsesExplicitDevelopmentOverride() {
    let dependencies = VirGLRuntimeDependencies.resolve(
        environment: [VirGLRuntimeDependencies.environmentOverrideKey: "/tmp/ezvm-virgl-test"]
    )
    #expect(dependencies.directoryURL.path == "/tmp/ezvm-virgl-test")
    #expect(dependencies.virglRendererURL.lastPathComponent == "libvirglrenderer.1.dylib")
    #expect(dependencies.epoxyURL.lastPathComponent == "libepoxy.0.dylib")
    #expect(dependencies.eglURL.lastPathComponent == "libEGL.dylib")
    #expect(dependencies.glesURL.lastPathComponent == "libGLESv2.dylib")
}

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

@Test func rendererExecutorPollsWithoutBlockingQueuedWork() {
    let executor = RendererExecutor()
    defer { executor.stop() }
    let lock = NSLock()
    let polled = DispatchSemaphore(value: 0)
    let jobRan = DispatchSemaphore(value: 0)
    var pollCount = 0

    executor.configurePolling {
        lock.lock()
        pollCount += 1
        let finished = pollCount >= 3
        lock.unlock()
        if finished {
            executor.setPollingEnabled(false)
            polled.signal()
        }
    }
    executor.setPollingEnabled(true)
    executor.async { jobRan.signal() }

    #expect(jobRan.wait(timeout: .now() + 1) == .success)
    #expect(polled.wait(timeout: .now() + 1) == .success)
    lock.lock()
    let finalPollCount = pollCount
    lock.unlock()
    #expect(finalPollCount >= 3)
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

@Test func controlAndCursorCommandsAreConfinedToTheirVirtqueues() {
    #expect(VirtioGPU.command(.getDisplayInfo, isValidOn: 0))
    #expect(VirtioGPU.command(.submit3D, isValidOn: 0))
    #expect(!VirtioGPU.command(.updateCursor, isValidOn: 0))
    #expect(!VirtioGPU.command(.getDisplayInfo, isValidOn: 1))
    #expect(VirtioGPU.command(.updateCursor, isValidOn: 1))
    #expect(VirtioGPU.command(.moveCursor, isValidOn: 1))
    #expect(!VirtioGPU.command(.moveCursor, isValidOn: 2))
}

@Test func pixelAllocationUsesCheckedProductionLimits() {
    #expect(VirtioGPU.pixelByteCount(width: 1, height: 1) == 4)
    #expect(VirtioGPU.pixelByteCount(width: 8_192, height: 8_192) == 256 * 1024 * 1024)
    #expect(VirtioGPU.pixelByteCount(width: 0, height: 1) == nil)
    #expect(VirtioGPU.pixelByteCount(width: 8_193, height: 1) == nil)
    #expect(VirtioGPU.pixelByteCount(width: UInt32.max, height: UInt32.max) == nil)
}

@Test func resourceRectValidationCannotOverflowOrEscapeTheResource() {
    let full = VirtioGPU.Rect(x: 0, y: 0, width: 1280, height: 720)
    let edge = VirtioGPU.Rect(x: 1279, y: 719, width: 1, height: 1)
    let outside = VirtioGPU.Rect(x: 1279, y: 719, width: 2, height: 1)
    let overflowing = VirtioGPU.Rect(x: UInt32.max, y: 0, width: 2, height: 1)
    let empty = VirtioGPU.Rect(x: 0, y: 0, width: 0, height: 1)

    #expect(VirtioGPU.rectIsContained(full, resourceWidth: 1280, resourceHeight: 720))
    #expect(VirtioGPU.rectIsContained(edge, resourceWidth: 1280, resourceHeight: 720))
    #expect(!VirtioGPU.rectIsContained(outside, resourceWidth: 1280, resourceHeight: 720))
    #expect(!VirtioGPU.rectIsContained(overflowing, resourceWidth: 1280, resourceHeight: 720))
    #expect(!VirtioGPU.rectIsContained(empty, resourceWidth: 1280, resourceHeight: 720))
}

@Test func cursorCommandsDecodeTheVirtioGPUWireLayout() throws {
    var request = Data()
    request.appendLittleEndian(VirtioGPU.Command.updateCursor.rawValue)
    request.appendLittleEndian(UInt32(0))
    request.appendLittleEndian(UInt64(0))
    request.appendLittleEndian(UInt32(0))
    request.appendLittleEndian(UInt32(0))
    request.appendLittleEndian(UInt32(0)) // scanout
    request.appendLittleEndian(UInt32(321))
    request.appendLittleEndian(UInt32(123))
    request.appendLittleEndian(UInt32(0)) // position padding
    request.appendLittleEndian(UInt32(42))
    request.appendLittleEndian(UInt32(7))
    request.appendLittleEndian(UInt32(9))
    request.appendLittleEndian(UInt32(0)) // cursor padding

    let update = try #require(VirtioGPU.CursorUpdate(request))
    #expect(update.position == .init(scanoutID: 0, x: 321, y: 123))
    #expect(update.resourceID == 42)
    #expect(update.hotX == 7)
    #expect(update.hotY == 9)
    #expect(VirtioGPU.CursorUpdate(Data(request.dropLast())) == nil)
}

@Test func threeDimensionalResourceLimitsRejectPathologicalAllocations() {
    #expect(VirtioGPU.valid3DResourceDimensions(
        width: 1280, height: 720, depth: 1, arraySize: 1, lastLevel: 0, sampleCount: 0
    ))
    #expect(!VirtioGPU.valid3DResourceDimensions(
        width: UInt32.max, height: UInt32.max, depth: UInt32.max,
        arraySize: UInt32.max, lastLevel: UInt32.max, sampleCount: UInt32.max
    ))
    #expect(!VirtioGPU.valid3DResourceDimensions(
        width: 8192, height: 8192, depth: 8, arraySize: 1, lastLevel: 0, sampleCount: 0
    ))
    #expect(!VirtioGPU.valid3DResourceDimensions(
        width: 64, height: 64, depth: 1, arraySize: 1, lastLevel: 16, sampleCount: 0
    ))
}
