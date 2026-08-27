import XCTest
import CryptoKit
@testable import EZVMCore

#if arch(arm64)
@MainActor
final class VMRunningRegistryTests: XCTestCase {
    private func makeRegistryPair() throws -> (VMRunningRegistry, VMRunningRegistry) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZVMRunLeaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (VMRunningRegistry(lockDirectory: directory), VMRunningRegistry(lockDirectory: directory))
    }

    func testLeaseIsExclusiveAcrossEquivalentPaths() {
        let registry = VMRunningRegistry()
        let root = URL(fileURLWithPath: "/tmp/EZVM Lease Test")

        let first = registry.acquire(rootPath: root)

        XCTAssertNotNil(first)
        let equivalent = URL(fileURLWithPath: "/tmp/../tmp/EZVM Lease Test")
        XCTAssertNil(registry.acquire(rootPath: equivalent))
        XCTAssertEqual(registry.phase(rootPath: root), .starting)
    }

    func testOnlyOwnerCanTransitionAndReleaseLease() throws {
        let registry = VMRunningRegistry()
        let root = URL(fileURLWithPath: "/tmp/EZVM Lease Owner Test")
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
        let root = URL(fileURLWithPath: "/tmp/EZVM Repeated Restart Test")

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

    func testLeaseIsExclusiveAcrossRegistryInstances() throws {
        let (guiRegistry, headlessRegistry) = try makeRegistryPair()
        let root = URL(fileURLWithPath: "/tmp/EZVM Cross Process Lease Test")
        let lease = try XCTUnwrap(guiRegistry.acquire(rootPath: root))

        XCTAssertNil(headlessRegistry.acquire(rootPath: root))
        XCTAssertTrue(headlessRegistry.isRunning(rootPath: root))

        guiRegistry.release(lease)
        XCTAssertFalse(headlessRegistry.isRunning(rootPath: root))
        XCTAssertNotNil(headlessRegistry.acquire(rootPath: root))
    }

    func testDifferentMachinesCanRunConcurrently() throws {
        let (firstRegistry, secondRegistry) = try makeRegistryPair()
        XCTAssertNotNil(firstRegistry.acquire(rootPath: URL(fileURLWithPath: "/tmp/EZVM Concurrent A")))
        XCTAssertNotNil(secondRegistry.acquire(rootPath: URL(fileURLWithPath: "/tmp/EZVM Concurrent B")))
    }

    func testRegistryDeinitReleasesKernelLease() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZVMRunLeaseRecovery-\(UUID().uuidString)", isDirectory: true)
        let root = URL(fileURLWithPath: "/tmp/EZVM Crash Recovery")
        var registry: VMRunningRegistry? = VMRunningRegistry(lockDirectory: directory)
        XCTAssertNotNil(registry?.acquire(rootPath: root))
        registry = nil

        let recovered = VMRunningRegistry(lockDirectory: directory)
        XCTAssertNotNil(recovered.acquire(rootPath: root))
    }

    func testResourcePolicyAllowsCPUOvercommitButReportsIt() {
        let policy = VMHostResourcePolicy(hostCPUCount: 8, hostMemoryBytes: 16 * 1_024 * 1_024 * 1_024)
        let result = policy.assess(existing: [.init(cpuCount: 6, memoryBytes: 4 * 1_024 * 1_024 * 1_024)],
                                   requested: .init(cpuCount: 4, memoryBytes: 4 * 1_024 * 1_024 * 1_024))
        XCTAssertTrue(result.allowed)
        XCTAssertEqual(result.projected.cpuCount, 10)
        XCTAssertTrue(result.warnings.contains { $0.contains("overcommitted") })
    }

    func testResourcePolicyWarnsAtEightyPercentAndRejectsAboveNinetyPercent() {
        let gib = UInt64(1_024 * 1_024 * 1_024)
        let policy = VMHostResourcePolicy(hostCPUCount: 8, hostMemoryBytes: 10 * gib)
        let warning = policy.assess(existing: [.init(cpuCount: 2, memoryBytes: 6 * gib)],
                                    requested: .init(cpuCount: 2, memoryBytes: 2 * gib + 1))
        XCTAssertTrue(warning.allowed)
        XCTAssertFalse(warning.warnings.isEmpty)
        let rejected = policy.assess(existing: [.init(cpuCount: 2, memoryBytes: 8 * gib)],
                                     requested: .init(cpuCount: 2, memoryBytes: gib + 1))
        XCTAssertFalse(rejected.allowed)
        XCTAssertTrue(rejected.denialReason?.contains("90%") == true)
    }

    func testResourcePolicyRejectsMoreThanTwoTimesCPUOvercommit() {
        let policy = VMHostResourcePolicy(hostCPUCount: 8, hostMemoryBytes: 16 * 1_024 * 1_024 * 1_024)
        let result = policy.assess(existing: [.init(cpuCount: 12, memoryBytes: 2 * 1_024 * 1_024 * 1_024)],
                                   requested: .init(cpuCount: 5, memoryBytes: 2 * 1_024 * 1_024 * 1_024))
        XCTAssertFalse(result.allowed)
        XCTAssertTrue(result.denialReason?.contains("twice") == true)
    }

    func testRegistryAggregatesResourcesAcrossInstances() throws {
        let gib = UInt64(1_024 * 1_024 * 1_024)
        let (first, second) = try makeRegistryPair()
        let firstLease = try XCTUnwrap(first.acquire(rootPath: URL(fileURLWithPath: "/tmp/EZVM Resource A")))
        XCTAssertTrue(try XCTUnwrap(first.configureResources(firstLease, cpuCount: 4, memoryBytes: 6 * gib,
                                                             policy: .init(hostCPUCount: 8, hostMemoryBytes: 10 * gib))).allowed)
        let secondLease = try XCTUnwrap(second.acquire(rootPath: URL(fileURLWithPath: "/tmp/EZVM Resource B")))
        let result = try XCTUnwrap(second.configureResources(secondLease, cpuCount: 2, memoryBytes: 4 * gib,
                                                             policy: .init(hostCPUCount: 8, hostMemoryBytes: 10 * gib)))
        XCTAssertFalse(result.allowed)
    }

    func testResourceAdmissionFailsClosedWhenLockedMetadataIsCorrupt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZVMRunLeaseCorruption-\(UUID().uuidString)", isDirectory: true)
        let first = VMRunningRegistry(lockDirectory: directory)
        let second = VMRunningRegistry(lockDirectory: directory)
        let firstRoot = URL(fileURLWithPath: "/tmp/EZVM Corrupt Resource A")
        let firstLease = try XCTUnwrap(first.acquire(rootPath: firstRoot))
        let gib = UInt64(1_024 * 1_024 * 1_024)
        XCTAssertNotNil(first.configureResources(firstLease, cpuCount: 2, memoryBytes: 2 * gib))

        let key = firstRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        try Data("not json".utf8).write(to: directory.appendingPathComponent("\(digest).json"), options: .atomic)

        let secondLease = try XCTUnwrap(second.acquire(rootPath: URL(fileURLWithPath: "/tmp/EZVM Corrupt Resource B")))
        XCTAssertNil(second.configureResources(secondLease, cpuCount: 1, memoryBytes: gib))
    }
}
#endif
