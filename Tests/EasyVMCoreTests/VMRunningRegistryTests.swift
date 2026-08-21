import XCTest
@testable import EasyVMCore

#if arch(arm64)
@MainActor
final class VMRunningRegistryTests: XCTestCase {
    func testLeaseIsExclusiveAcrossEquivalentPaths() {
        let registry = VMRunningRegistry()
        let root = URL(fileURLWithPath: "/tmp/EasyVM Lease Test")

        let first = registry.acquire(rootPath: root)

        XCTAssertNotNil(first)
        let equivalent = URL(fileURLWithPath: "/tmp/../tmp/EasyVM Lease Test")
        XCTAssertNil(registry.acquire(rootPath: equivalent))
        XCTAssertEqual(registry.phase(rootPath: root), .starting)
    }

    func testOnlyOwnerCanTransitionAndReleaseLease() throws {
        let registry = VMRunningRegistry()
        let root = URL(fileURLWithPath: "/tmp/EasyVM Lease Owner Test")
        let lease = try XCTUnwrap(registry.acquire(rootPath: root))
        let impostor = VMRunLease(id: UUID(), rootPath: lease.rootPath)

        registry.transition(impostor, to: .running)
        XCTAssertEqual(registry.phase(rootPath: root), .starting)
        registry.release(impostor)
        XCTAssertTrue(registry.isRunning(rootPath: root))

        registry.transition(lease, to: .running)
        XCTAssertEqual(registry.phase(rootPath: root), .running)
        registry.transition(lease, to: .stopping)
        XCTAssertEqual(registry.phase(rootPath: root), .stopping)
        registry.release(lease)
        XCTAssertFalse(registry.isRunning(rootPath: root))
    }

    func testRepeatedShutdownRestartAndStaleCallbackSafety() throws {
        let registry = VMRunningRegistry()
        let root = URL(fileURLWithPath: "/tmp/EasyVM Repeated Restart Test")

        for _ in 0..<100 {
            let previous = try XCTUnwrap(registry.acquire(rootPath: root))
            registry.transition(previous, to: .running)
            registry.transition(previous, to: .stopping)
            registry.release(previous)

            let restarted = try XCTUnwrap(registry.acquire(rootPath: root))
            registry.release(previous) // a delayed delegate callback from the old VM
            XCTAssertEqual(registry.phase(rootPath: root), .starting)
            registry.transition(restarted, to: .running)
            registry.release(restarted)
        }
        XCTAssertFalse(registry.isRunning(rootPath: root))
    }
}
#endif
