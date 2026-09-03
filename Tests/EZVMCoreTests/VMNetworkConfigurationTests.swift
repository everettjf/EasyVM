import XCTest
import Virtualization
import Darwin
@testable import EZVMCore

#if arch(arm64)
final class VMNetworkConfigurationTests: XCTestCase {
    func testNamedNetworkOwnershipIsExclusiveAcrossRegistriesAndRecoversAfterRelease() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZVMNetworkLease-\(UUID().uuidString)", isDirectory: true)
        let first = VMNetNamedNetworkOwnershipRegistry(directory: directory)
        let second = VMNetNamedNetworkOwnershipRegistry(directory: directory)

        guard case let .acquired(lease) = first.acquire(identifier: "team-network", signature: "shared|24") else {
            return XCTFail("The first registry should own the named network")
        }
        guard case let .alreadyOwned(signatureMatches) = second.acquire(
            identifier: "team-network",
            signature: "shared|24"
        ) else {
            return XCTFail("A second registry must not reserve an active named network")
        }
        XCTAssertTrue(signatureMatches)

        first.release(lease)
        guard case .acquired = second.acquire(identifier: "team-network", signature: "shared|24") else {
            return XCTFail("Ownership should become available after an orderly release")
        }
    }

    func testNamedNetworkOwnershipReportsConfigurationMismatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZVMNetworkLeaseMismatch-\(UUID().uuidString)", isDirectory: true)
        let first = VMNetNamedNetworkOwnershipRegistry(directory: directory)
        let second = VMNetNamedNetworkOwnershipRegistry(directory: directory)
        guard case .acquired = first.acquire(identifier: "private-lab", signature: "host|10.0.0.0") else {
            return XCTFail("The first registry should own the named network")
        }
        guard case let .alreadyOwned(signatureMatches) = second.acquire(
            identifier: "private-lab",
            signature: "host|10.1.0.0"
        ) else {
            return XCTFail("Expected an ownership conflict")
        }
        XCTAssertFalse(signatureMatches)
    }

    func testNamedNetworkOwnershipRecoversAfterOwnerProcessTerminates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZVMNetworkLeaseProcess-\(UUID().uuidString)", isDirectory: true)
        let readyURL = directory.appendingPathComponent("ready")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "VMNetworkConfigurationTests/testNamedNetworkOwnershipHolderChild",
            Bundle(for: VMNetworkConfigurationTests.self).bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["EZVM_VMNET_LEASE_DIRECTORY"] = directory.path
        environment["EZVM_VMNET_LEASE_READY"] = readyURL.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: readyURL.path), Date() < deadline {
            usleep(20_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyURL.path), "Child process did not acquire its lease")

        let contender = VMNetNamedNetworkOwnershipRegistry(directory: directory)
        guard case let .alreadyOwned(signatureMatches) = contender.acquire(
            identifier: "process-network",
            signature: "shared|process"
        ) else {
            return XCTFail("The parent must observe the child's kernel-backed lease")
        }
        XCTAssertTrue(signatureMatches)

        process.terminate()
        process.waitUntilExit()
        guard case .acquired = contender.acquire(identifier: "process-network", signature: "shared|process") else {
            return XCTFail("A terminated owner must not strand the named network")
        }
    }

    func testNamedNetworkOwnershipHolderChild() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directoryPath = environment["EZVM_VMNET_LEASE_DIRECTORY"],
              let readyPath = environment["EZVM_VMNET_LEASE_READY"] else { return }
        let registry = VMNetNamedNetworkOwnershipRegistry(
            directory: URL(fileURLWithPath: directoryPath, isDirectory: true)
        )
        guard case .acquired = registry.acquire(
            identifier: "process-network",
            signature: "shared|process"
        ) else {
            return XCTFail("Child could not acquire the network lease")
        }
        try Data().write(to: URL(fileURLWithPath: readyPath), options: .atomic)
        RunLoop.current.run(until: Date().addingTimeInterval(30))
    }

    func testNetworkDisconnectGuidanceIsActionableSanitizedAndBounded() {
        let unsafeDetail = " bridge0\n\u{1} unavailable "
            + String(repeating: "x", count: 300)
        let message = VMNetworkFailureGuidance.disconnectReason(
            frameworkDescription: unsafeDetail
        )

        XCTAssertTrue(message.contains("Check the selected interface, VPN, and network access"))
        XCTAssertTrue(message.contains("Framework detail: bridge0 unavailable"))
        XCTAssertFalse(message.contains("\n"))
        XCTAssertFalse(message.contains("\u{1}"))
        let detail = try? XCTUnwrap(message.components(separatedBy: "Framework detail: ").last)
        XCTAssertLessThanOrEqual(detail?.count ?? .max, VMNetworkFailureGuidance.maximumFrameworkDetailCharacters)
    }

    func testNetworkDisconnectGuidanceOmitsEmptyFrameworkDetail() {
        let message = VMNetworkFailureGuidance.disconnectReason(
            frameworkDescription: "\n\t\u{0}"
        )

        XCTAssertFalse(message.contains("Framework detail"))
        XCTAssertTrue(message.hasSuffix("then reconnect."))
    }

    func testNetworkRuntimeTrackerDistinguishesPreparingConnectedAndDegraded() {
        var tracker = VMNetworkRuntimeTracker(deviceCount: 2)
        XCTAssertEqual(tracker.state, .preparing(deviceCount: 2))

        tracker.markStarted()
        XCTAssertEqual(tracker.state, .connected(deviceCount: 2))

        tracker.markDisconnected(deviceIndex: 1, reason: "Interface unavailable")
        XCTAssertEqual(
            tracker.state,
            .degraded(
                deviceCount: 2,
                issues: [VMNetworkDeviceIssue(deviceIndex: 1, reason: "Interface unavailable")]
            )
        )
    }

    func testNetworkRuntimeTrackerReconnectsOnlyDisconnectedAdapters() {
        var tracker = VMNetworkRuntimeTracker(deviceCount: 2)
        tracker.markStarted()

        XCTAssertFalse(tracker.beginReconnect(deviceIndex: 0))
        tracker.markDisconnected(deviceIndex: 0, reason: "Link lost")
        XCTAssertTrue(tracker.beginReconnect(deviceIndex: 0))
        XCTAssertFalse(tracker.beginReconnect(deviceIndex: 0))
        XCTAssertEqual(
            tracker.state,
            .reconnecting(
                deviceCount: 2,
                issues: [VMNetworkDeviceIssue(deviceIndex: 0, reason: "Link lost")],
                deviceIndices: [0]
            )
        )

        tracker.markConnected(deviceIndex: 0)
        XCTAssertEqual(tracker.state, .connected(deviceCount: 2))
    }

    func testNetworkRuntimeTrackerAllowsRetryAfterReconnectFails() {
        var tracker = VMNetworkRuntimeTracker(deviceCount: 1)
        tracker.markStarted()
        tracker.markDisconnected(deviceIndex: 0, reason: "Link lost")

        XCTAssertTrue(tracker.beginReconnect(deviceIndex: 0))
        tracker.markDisconnected(deviceIndex: 0, reason: "Interface is still unavailable")
        XCTAssertEqual(
            tracker.state,
            .degraded(
                deviceCount: 1,
                issues: [
                    VMNetworkDeviceIssue(
                        deviceIndex: 0,
                        reason: "Interface is still unavailable"
                    )
                ]
            )
        )
        XCTAssertTrue(tracker.beginReconnect(deviceIndex: 0))
    }

    func testNetworkRuntimeTrackerDoesNotClaimSuccessWhenReconnectRequestIsOnlyAccepted() {
        var tracker = VMNetworkRuntimeTracker(deviceCount: 1)
        tracker.markStarted()
        tracker.markDisconnected(deviceIndex: 0, reason: "Interface changed")

        XCTAssertEqual(tracker.beginAutomaticReconnect(deviceIndex: 0), 1)
        XCTAssertTrue(tracker.markReconnectRequestAccepted(deviceIndex: 0))
        XCTAssertEqual(tracker.stabilizingIndices, [0])
        XCTAssertEqual(tracker.automaticReconnectAttempts[0], 1)
        XCTAssertEqual(
            tracker.state,
            .reconnecting(
                deviceCount: 1,
                issues: [VMNetworkDeviceIssue(deviceIndex: 0, reason: "Interface changed")],
                deviceIndices: [0]
            )
        )
        XCTAssertFalse(tracker.beginReconnect(deviceIndex: 0))
        XCTAssertNil(tracker.beginAutomaticReconnect(deviceIndex: 0))

        tracker.markConnected(deviceIndex: 0)
        XCTAssertEqual(tracker.state, .connected(deviceCount: 1))
        XCTAssertTrue(tracker.stabilizingIndices.isEmpty)
        XCTAssertNil(tracker.automaticReconnectAttempts[0])
    }

    func testNetworkRuntimeTrackerLateFailureConsumesTheNextRetryBudget() {
        var tracker = VMNetworkRuntimeTracker(deviceCount: 1)
        tracker.markStarted()
        tracker.markDisconnected(deviceIndex: 0, reason: "Interface changed")

        XCTAssertEqual(tracker.beginAutomaticReconnect(deviceIndex: 0), 1)
        XCTAssertTrue(tracker.markReconnectRequestAccepted(deviceIndex: 0))
        tracker.markDisconnected(deviceIndex: 0, reason: "Late framework disconnect")

        XCTAssertTrue(tracker.stabilizingIndices.isEmpty)
        XCTAssertEqual(tracker.beginAutomaticReconnect(deviceIndex: 0), 3)
        XCTAssertEqual(tracker.automaticReconnectAttempts[0], 2)
    }

    func testNetworkRuntimeTrackerKeepsIndependentAdapterFailures() {
        var tracker = VMNetworkRuntimeTracker(deviceCount: 3)
        tracker.markStarted()
        tracker.markDisconnected(deviceIndex: 2, reason: "Third")
        tracker.markDisconnected(deviceIndex: 0, reason: "First")
        tracker.markDisconnected(deviceIndex: 99, reason: "Unknown")

        XCTAssertEqual(
            tracker.state,
            .degraded(
                deviceCount: 3,
                issues: [
                    VMNetworkDeviceIssue(deviceIndex: 0, reason: "First"),
                    VMNetworkDeviceIssue(deviceIndex: 2, reason: "Third"),
                ]
            )
        )

        tracker.markConnected(deviceIndex: 0)
        XCTAssertEqual(
            tracker.state,
            .degraded(
                deviceCount: 3,
                issues: [VMNetworkDeviceIssue(deviceIndex: 2, reason: "Third")]
            )
        )
    }

    func testNetworkRuntimeTrackerDoesNotClaimConnectivityDuringHostSleep() {
        var tracker = VMNetworkRuntimeTracker(deviceCount: 2)
        tracker.markStarted()
        tracker.markHostSleeping()

        XCTAssertEqual(tracker.state, .hostSleeping(deviceCount: 2))
        XCTAssertEqual(tracker.markHostAwake(), [])
        XCTAssertEqual(tracker.state, .connected(deviceCount: 2))
    }

    func testNetworkRuntimeTrackerRecoversOnlyAdaptersDisconnectedDuringSleep() {
        var tracker = VMNetworkRuntimeTracker(deviceCount: 3)
        tracker.markStarted()
        tracker.markDisconnected(deviceIndex: 0, reason: "Before sleep")
        XCTAssertTrue(tracker.beginReconnect(deviceIndex: 0))

        tracker.markHostSleeping()
        tracker.markDisconnected(deviceIndex: 2, reason: "Interface removed during sleep")
        XCTAssertEqual(tracker.state, .hostSleeping(deviceCount: 3))
        XCTAssertEqual(tracker.markHostAwake(), [0, 2])
        XCTAssertEqual(
            tracker.state,
            .degraded(
                deviceCount: 3,
                issues: [
                    VMNetworkDeviceIssue(deviceIndex: 0, reason: "Before sleep"),
                    VMNetworkDeviceIssue(deviceIndex: 2, reason: "Interface removed during sleep"),
                ]
            )
        )
        XCTAssertTrue(tracker.beginReconnect(deviceIndex: 0))
    }

    func testNetworkRuntimeTrackerBoundsAutomaticReconnectsAndResetsAfterSuccess() {
        var tracker = VMNetworkRuntimeTracker(deviceCount: 1)
        tracker.markStarted()
        tracker.markDisconnected(deviceIndex: 0, reason: "Interface changed")

        XCTAssertEqual(tracker.beginAutomaticReconnect(deviceIndex: 0), 1)
        XCTAssertEqual(
            tracker.state,
            .reconnecting(
                deviceCount: 1,
                issues: [VMNetworkDeviceIssue(deviceIndex: 0, reason: "Interface changed")],
                deviceIndices: [0]
            )
        )
        XCTAssertNil(tracker.beginAutomaticReconnect(deviceIndex: 0))
        tracker.markDisconnected(deviceIndex: 0, reason: "Interface still unavailable")
        XCTAssertEqual(tracker.beginAutomaticReconnect(deviceIndex: 0), 3)
        tracker.markDisconnected(deviceIndex: 0, reason: "Interface still unavailable")
        XCTAssertNil(tracker.beginAutomaticReconnect(deviceIndex: 0))

        tracker.markConnected(deviceIndex: 0)
        tracker.markDisconnected(deviceIndex: 0, reason: "VPN changed")
        XCTAssertEqual(tracker.beginAutomaticReconnect(deviceIndex: 0), 1)
    }

    func testNetworkRuntimeTrackerSuspendsAndRenewsAutomaticRecoveryAcrossSleep() {
        var tracker = VMNetworkRuntimeTracker(deviceCount: 1)
        tracker.markStarted()
        tracker.markDisconnected(deviceIndex: 0, reason: "Interface changed")
        XCTAssertEqual(tracker.beginAutomaticReconnect(deviceIndex: 0), 1)

        tracker.markHostSleeping()
        XCTAssertNil(tracker.beginAutomaticReconnect(deviceIndex: 0))
        XCTAssertEqual(tracker.markHostAwake(), [0])
        XCTAssertEqual(tracker.beginAutomaticReconnect(deviceIndex: 0), 1)
    }

    func testNetworkRuntimeTrackerManualRecoveryRenewsAutomaticBudget() {
        var tracker = VMNetworkRuntimeTracker(deviceCount: 1)
        tracker.markStarted()
        tracker.markDisconnected(deviceIndex: 0, reason: "Interface changed")
        XCTAssertEqual(tracker.beginAutomaticReconnect(deviceIndex: 0), 1)
        tracker.markDisconnected(deviceIndex: 0, reason: "Still unavailable")
        XCTAssertEqual(tracker.beginAutomaticReconnect(deviceIndex: 0), 3)
        tracker.markDisconnected(deviceIndex: 0, reason: "Still unavailable")

        tracker.resetAutomaticReconnectAttempts(deviceIndex: 0)
        XCTAssertEqual(tracker.beginAutomaticReconnect(deviceIndex: 0), 1)
    }

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

    func testMachineStateSupportExplainsEveryUnsupportedConfiguration() {
        XCTAssertNil(VMMachineStateSupport.unavailabilityReason(
            backendSupportsSaveRestore: true,
            configurationValidationFailure: nil,
            attachedAccessoryCount: 0
        ))
        XCTAssertEqual(
            VMMachineStateSupport.unavailabilityReason(
                backendSupportsSaveRestore: false,
                configurationValidationFailure: nil,
                attachedAccessoryCount: 0
            ),
            "Custom VirGL state cannot be saved."
        )
        XCTAssertEqual(
            VMMachineStateSupport.unavailabilityReason(
                backendSupportsSaveRestore: true,
                configurationValidationFailure: nil,
                attachedAccessoryCount: 1
            ),
            "Disconnect USB accessories before saving machine state."
        )
        XCTAssertEqual(
            VMMachineStateSupport.unavailabilityReason(
                backendSupportsSaveRestore: true,
                configurationValidationFailure: "Unsupported device",
                attachedAccessoryCount: 0
            ),
            "This virtual machine configuration cannot save state: Unsupported device"
        )
    }

    func testMachineStateSupportUsesMostActionableReasonFirst() {
        XCTAssertEqual(
            VMMachineStateSupport.unavailabilityReason(
                backendSupportsSaveRestore: true,
                configurationValidationFailure: "Unsupported device",
                attachedAccessoryCount: 2
            ),
            "Disconnect USB accessories before saving machine state."
        )
        XCTAssertEqual(
            VMMachineStateSupport.unavailabilityReason(
                backendSupportsSaveRestore: false,
                configurationValidationFailure: "Unsupported device",
                attachedAccessoryCount: 2
            ),
            "Custom VirGL state cannot be saved."
        )
    }

    func testUSBOperationBlocksMachineStateBeforeAttachmentCompletes() {
        XCTAssertEqual(
            VMMachineStateSupport.unavailabilityReason(
                backendSupportsSaveRestore: true,
                configurationValidationFailure: nil,
                attachedAccessoryCount: 0,
                usbOperationInProgress: true
            ),
            "Wait for the USB connection or disconnection to finish before saving machine state."
        )
        XCTAssertEqual(
            VMMachineStateSupport.unavailabilityReason(
                backendSupportsSaveRestore: true,
                configurationValidationFailure: nil,
                attachedAccessoryCount: 1,
                usbOperationInProgress: true
            ),
            "Wait for the USB connection or disconnection to finish before saving machine state."
        )
    }

    func testUSBListenerRejectsRegistrationCompletionAfterStop() {
        var lifecycle = VMUSBListenerLifecycle()
        let token = try! XCTUnwrap(lifecycle.beginRegistration())

        XCTAssertFalse(lifecycle.stop())
        XCTAssertFalse(lifecycle.completeRegistration(token: token))
        XCTAssertFalse(lifecycle.isRegistered)
        XCTAssertFalse(lifecycle.acceptsAccessoryCallbacks)
    }

    func testUSBListenerAcceptsCallbacksOnlyAfterCurrentRegistrationCompletes() {
        var lifecycle = VMUSBListenerLifecycle()
        let currentToken = try! XCTUnwrap(lifecycle.beginRegistration())
        XCTAssertTrue(lifecycle.isRegistering)
        XCTAssertNil(lifecycle.beginRegistration())
        XCTAssertFalse(lifecycle.acceptsAccessoryCallbacks)
        XCTAssertTrue(lifecycle.completeRegistration(token: currentToken))
        XCTAssertFalse(lifecycle.isRegistering)
        XCTAssertTrue(lifecycle.isRegistered)
        XCTAssertTrue(lifecycle.acceptsAccessoryCallbacks)
        XCTAssertTrue(lifecycle.stop())
        XCTAssertFalse(lifecycle.acceptsAccessoryCallbacks)
    }

    func testUSBListenerCanRegisterAgainAfterACompletedUnregistration() {
        var lifecycle = VMUSBListenerLifecycle()
        let first = try! XCTUnwrap(lifecycle.beginRegistration())
        XCTAssertTrue(lifecycle.completeRegistration(token: first))
        XCTAssertNil(lifecycle.beginRegistration())
        XCTAssertTrue(lifecycle.stop())

        let second = try! XCTUnwrap(lifecycle.beginRegistration())
        XCTAssertTrue(lifecycle.completeRegistration(token: second))
        XCTAssertTrue(lifecycle.isRegistered)
    }

    func testUSBListenerCanRetryAfterRegistrationFailure() {
        var lifecycle = VMUSBListenerLifecycle()
        let failedToken = try! XCTUnwrap(lifecycle.beginRegistration())

        XCTAssertTrue(lifecycle.failRegistration(token: failedToken))
        let retryToken = try! XCTUnwrap(lifecycle.beginRegistration())
        XCTAssertTrue(lifecycle.completeRegistration(token: retryToken))
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

    func testUSBDescriptorPrefersReadableRegistryNamesWithoutDuplicatingVendor() {
        let named = VMUSBDeviceDescriptorSummary(
            registryID: 1,
            vendorID: 0x1234,
            productID: 0xABCD,
            manufacturerName: "Acme",
            productName: "Fast Disk"
        )
        XCTAssertEqual(named.title, "Acme Fast Disk")
        XCTAssertEqual(named.identifier, "1234:ABCD")
        XCTAssertEqual(named.menuTitle, "Acme Fast Disk · 1234:ABCD")

        let alreadyNamed = VMUSBDeviceDescriptorSummary(
            registryID: 2,
            vendorID: 0x1234,
            productID: 0xABCD,
            manufacturerName: "Acme",
            productName: "ACME Secure Key"
        )
        XCTAssertEqual(alreadyNamed.title, "ACME Secure Key")
    }

    func testUSBDescriptorSanitizesUntrustedRegistryNamesAndFallsBackToIdentifier() {
        let sanitized = VMUSBDeviceDescriptorSummary(
            registryID: 1,
            vendorID: 0x1234,
            productID: 0xABCD,
            manufacturerName: "  Acme\n",
            productName: "Disk\u{0000}\u{0007}  "
        )
        XCTAssertEqual(sanitized.title, "Acme Disk")

        let fallback = VMUSBDeviceDescriptorSummary(
            registryID: 2,
            vendorID: 0x1234,
            productID: 0xABCD,
            manufacturerName: "\n\t",
            productName: "\u{0000}"
        )
        XCTAssertEqual(fallback.title, "USB 1234:ABCD")
        XCTAssertEqual(fallback.menuTitle, fallback.title)
    }

    func testUSBDescriptorBoundsLongRegistryNames() {
        let summary = VMUSBDeviceDescriptorSummary(
            registryID: 1,
            vendorID: 1,
            productID: 2,
            productName: String(repeating: "x", count: 100)
        )
        XCTAssertEqual(summary.productName?.count, 80)
        XCTAssertEqual(summary.title.count, 80)
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

    func testUSBDisconnectReconciliationReportsUnexpectedDisconnectExactlyOnce() {
        var attached: Set<UInt64> = [17]
        var operations: [UInt64: VMUSBDeviceOperation] = [17: .attaching]
        var tokens: [UInt64: UUID] = [17: UUID()]

        XCTAssertEqual(
            VMUSBControllerSupport.reconcileDisconnect(
                registryID: 17,
                attachedRegistryIDs: &attached,
                operations: &operations,
                operationTokens: &tokens
            ),
            .unexpected
        )
        XCTAssertEqual(
            VMUSBControllerSupport.reconcileDisconnect(
                registryID: 17,
                attachedRegistryIDs: &attached,
                operations: &operations,
                operationTokens: &tokens
            ),
            .ignored
        )
        XCTAssertTrue(attached.isEmpty)
        XCTAssertTrue(operations.isEmpty)
        XCTAssertTrue(tokens.isEmpty)
    }

    func testUSBDisconnectReconciliationRecognizesExplicitDetach() {
        var attached: Set<UInt64> = [42]
        var operations: [UInt64: VMUSBDeviceOperation] = [42: .detaching]
        var tokens: [UInt64: UUID] = [42: UUID()]

        XCTAssertEqual(
            VMUSBControllerSupport.reconcileDisconnect(
                registryID: 42,
                attachedRegistryIDs: &attached,
                operations: &operations,
                operationTokens: &tokens
            ),
            .explicitDetach
        )
        XCTAssertTrue(attached.isEmpty)
        XCTAssertTrue(operations.isEmpty)
        XCTAssertTrue(tokens.isEmpty)
    }

    func testLateUSBDisconnectClearsStaleOperationWithoutInventingAttachment() {
        var attached: Set<UInt64> = []
        var operations: [UInt64: VMUSBDeviceOperation] = [9: .attaching]
        var tokens: [UInt64: UUID] = [9: UUID()]

        XCTAssertEqual(
            VMUSBControllerSupport.reconcileDisconnect(
                registryID: 9,
                attachedRegistryIDs: &attached,
                operations: &operations,
                operationTokens: &tokens
            ),
            .ignored
        )
        XCTAssertTrue(operations.isEmpty)
        XCTAssertTrue(tokens.isEmpty)
    }

    func testConsoleLogoutBatchDisconnectAndDuplicateDelegateCallbacksConverge() {
        var attached: Set<UInt64> = [17, 42]
        var operations: [UInt64: VMUSBDeviceOperation] = [17: .attaching, 42: .detaching]
        var tokens: [UInt64: UUID] = [17: UUID(), 42: UUID()]

        XCTAssertEqual(
            VMUSBControllerSupport.reconcileDisconnect(
                registryID: 17,
                attachedRegistryIDs: &attached,
                operations: &operations,
                operationTokens: &tokens
            ),
            .unexpected
        )
        XCTAssertEqual(
            VMUSBControllerSupport.reconcileDisconnect(
                registryID: 42,
                attachedRegistryIDs: &attached,
                operations: &operations,
                operationTokens: &tokens
            ),
            .explicitDetach
        )
        XCTAssertEqual(
            VMUSBControllerSupport.reconcileDisconnect(
                registryID: 17,
                attachedRegistryIDs: &attached,
                operations: &operations,
                operationTokens: &tokens
            ),
            .ignored
        )
        XCTAssertEqual(
            VMUSBControllerSupport.reconcileDisconnect(
                registryID: 42,
                attachedRegistryIDs: &attached,
                operations: &operations,
                operationTokens: &tokens
            ),
            .ignored
        )
        XCTAssertTrue(attached.isEmpty)
        XCTAssertTrue(operations.isEmpty)
        XCTAssertTrue(tokens.isEmpty)
    }

    func testUSBFailureSnapshotRetainsAttachedDevicesAndBlocksMachineState() {
        let device = VMUSBDeviceDescriptorSummary(
            registryID: 17,
            vendorID: 0x1234,
            productID: 0xABCD
        )
        let snapshot = VMUSBPassthroughSnapshot(
            devices: [device],
            attachedRegistryIDs: [17],
            operations: [:],
            notice: .detachFailed(deviceTitle: device.title, detail: "Busy")
        )

        XCTAssertTrue(snapshot.hasAttachedDevices)
        XCTAssertFalse(VMUSBControllerSupport.canSaveMachineState(
            backendSupportsSaveRestore: true,
            attachedAccessoryCount: snapshot.hasAttachedDevices ? 1 : 0
        ))
        XCTAssertFalse(snapshot.canChooseMoreAccessories)
        XCTAssertTrue(snapshot.notice?.message.contains("may still be attached") == true)
    }

    func testUSBSelectionCanRefreshOnlyWithoutAttachmentsOrOperations() {
        let device = VMUSBDeviceDescriptorSummary(
            registryID: 7,
            vendorID: 0x1234,
            productID: 0x5678
        )
        XCTAssertTrue(VMUSBPassthroughSnapshot(
            devices: [device],
            attachedRegistryIDs: []
        ).canChooseMoreAccessories)
        XCTAssertFalse(VMUSBPassthroughSnapshot(
            devices: [device],
            attachedRegistryIDs: [],
            operations: [device.registryID: .attaching]
        ).canChooseMoreAccessories)
        XCTAssertFalse(VMUSBPassthroughSnapshot(
            devices: [device],
            attachedRegistryIDs: [device.registryID]
        ).canChooseMoreAccessories)
    }

    func testUSBOperationStateDistinguishesAttachAndDetach() {
        var snapshot = VMUSBPassthroughSnapshot(
            devices: [],
            attachedRegistryIDs: [],
            operations: [7: .attaching],
            notice: nil
        )
        XCTAssertEqual(snapshot.operations[7], .attaching)

        snapshot.operations[7] = .detaching
        XCTAssertEqual(snapshot.operations[7], .detaching)
    }

    func testUnexpectedUSBDisconnectNoticeNamesDevice() {
        let notice = VMUSBPassthroughNotice.unexpectedDisconnect(
            deviceTitle: "USB 1234:ABCD"
        )

        XCTAssertEqual(
            notice.message,
            "USB 1234:ABCD was disconnected from the virtual machine."
        )
    }

    func testUSBFailureGuidanceProvidesSpecificRecoveryActions() {
        XCTAssertTrue(VMUSBFailureGuidance.message(
            for: .accessoryNotAccessible,
            fallback: "raw"
        ).contains("another app"))
        XCTAssertTrue(VMUSBFailureGuidance.message(
            for: .invalidAccessoryState,
            fallback: "raw"
        ).contains("reconnect"))
        XCTAssertTrue(VMUSBFailureGuidance.message(
            for: .controllerNotFound,
            fallback: "raw"
        ).contains("Restart the virtual machine"))
        XCTAssertTrue(VMUSBFailureGuidance.message(
            for: .deviceInitializationFailure,
            fallback: "raw"
        ).contains("may not support passthrough"))
        XCTAssertTrue(VMUSBFailureGuidance.message(
            for: .deviceNotFound,
            fallback: "raw"
        ).contains("approve it for EZVM again"))
    }

    func testUSBFrameworkErrorCodesMapToStableFailureKinds() {
        XCTAssertEqual(VMUSBFailureGuidance.classify(framework: .accessoryAccess, code: 2), .listenerAlreadyRegistered)
        XCTAssertEqual(VMUSBFailureGuidance.classify(framework: .accessoryAccess, code: 3), .accessoryNotAccessible)
        XCTAssertEqual(VMUSBFailureGuidance.classify(framework: .accessoryAccess, code: 4), .invalidAccessoryState)
        XCTAssertEqual(VMUSBFailureGuidance.classify(framework: .virtualization, code: 30001), .controllerNotFound)
        XCTAssertEqual(VMUSBFailureGuidance.classify(framework: .virtualization, code: 30002), .deviceAlreadyAttached)
        XCTAssertEqual(VMUSBFailureGuidance.classify(framework: .virtualization, code: 30003), .deviceInitializationFailure)
        XCTAssertEqual(VMUSBFailureGuidance.classify(framework: .virtualization, code: 30004), .deviceNotFound)
        XCTAssertEqual(VMUSBFailureGuidance.classify(framework: .other, code: 30004), .other)
    }

    func testUSBUnknownFailurePreservesFrameworkDescription() {
        XCTAssertEqual(
            VMUSBFailureGuidance.message(for: .other, fallback: "Framework detail"),
            "Framework detail"
        )
    }

    func testUSBDetachOnlyTreatsDeviceNotFoundAsDisconnected() {
        XCTAssertTrue(VMUSBFailureGuidance.confirmsDeviceIsDisconnected(.deviceNotFound))
        XCTAssertFalse(VMUSBFailureGuidance.confirmsDeviceIsDisconnected(.internalFailure))
        XCTAssertFalse(VMUSBFailureGuidance.confirmsDeviceIsDisconnected(.controllerNotFound))
        XCTAssertFalse(VMUSBFailureGuidance.confirmsDeviceIsDisconnected(.other))
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

    func testVMNetRejectsNonContiguousMasksAndNonNetworkSubnets() {
        XCTAssertTrue(VMModelFieldNetworkDevice(
            type: .VMNetShared,
            ipv4Subnet: "192.168.73.0",
            ipv4SubnetMask: "255.0.255.0"
        ).validationError(vmnetEntitlementGranted: true)?.contains("contiguous") == true)

        XCTAssertEqual(
            VMModelFieldNetworkDevice(
                type: .VMNetShared,
                ipv4Subnet: "192.168.73.42",
                ipv4SubnetMask: "255.255.255.0"
            ).validationError(vmnetEntitlementGranted: true),
            "The VMNet subnet must be a network address. For this mask, use 192.168.73.0."
        )
    }

    func testVMNetRejectsInvalidForwardingPortsAndDestinationsOutsideSubnet() {
        let zeroPort = VMModelFieldNetworkDevice.PortForwardingRule(
            transport: .tcp,
            externalPort: 0,
            internalAddress: "192.168.73.10",
            internalPort: 22
        )
        XCTAssertTrue(VMModelFieldNetworkDevice(
            type: .VMNetShared,
            portForwardingRules: [zeroPort]
        ).validationError(vmnetEntitlementGranted: true)?.contains("between 1 and 65535") == true)

        let outsideSubnet = VMModelFieldNetworkDevice.PortForwardingRule(
            transport: .tcp,
            externalPort: 2222,
            internalAddress: "192.168.74.10",
            internalPort: 22
        )
        XCTAssertTrue(VMModelFieldNetworkDevice(
            type: .VMNetShared,
            ipv4Subnet: "192.168.73.0",
            ipv4SubnetMask: "255.255.255.0",
            portForwardingRules: [outsideSubnet]
        ).validationError(vmnetEntitlementGranted: true)?.contains("usable address inside") == true)
    }

    func testVMNetRejectsUnavailableExternalInterface() {
        XCTAssertTrue(VMModelFieldNetworkDevice(
            type: .VMNetShared,
            externalInterface: "en99"
        ).validationError(
            vmnetEntitlementGranted: true,
            availableInterfaceNames: ["en0", "bridge0"]
        )?.contains("not available") == true)
    }

    func testVMNetCollectionPreflightRejectsConflictsBeforeCreation() {
        let firstRule = VMModelFieldNetworkDevice.PortForwardingRule(
            transport: .tcp,
            externalPort: 2222,
            internalAddress: "192.168.73.10",
            internalPort: 22
        )
        let secondRule = VMModelFieldNetworkDevice.PortForwardingRule(
            transport: .tcp,
            externalPort: 2222,
            internalAddress: "192.168.74.10",
            internalPort: 22
        )
        let first = VMModelFieldNetworkDevice(
            type: .VMNetShared,
            networkIdentifier: "lab",
            ipv4Subnet: "192.168.73.0",
            ipv4SubnetMask: "255.255.255.0",
            portForwardingRules: [firstRule]
        )
        let conflictingName = VMModelFieldNetworkDevice(
            type: .VMNetShared,
            networkIdentifier: "lab",
            ipv4Subnet: "192.168.74.0",
            ipv4SubnetMask: "255.255.255.0",
            portForwardingRules: [secondRule]
        )

        XCTAssertTrue(VMModelFieldNetworkDevice.collectionValidationError(
            [first, conflictingName],
            vmnetEntitlementGranted: true,
            availableInterfaceNames: []
        )?.contains("different settings") == true)

        let duplicatePort = VMModelFieldNetworkDevice(
            type: .VMNetShared,
            networkIdentifier: "other",
            ipv4Subnet: "192.168.74.0",
            ipv4SubnetMask: "255.255.255.0",
            portForwardingRules: [secondRule]
        )
        XCTAssertTrue(VMModelFieldNetworkDevice.collectionValidationError(
            [first, duplicatePort],
            vmnetEntitlementGranted: true,
            availableInterfaceNames: []
        )?.contains("forwarded more than once") == true)
    }

    func testVMNetCollectionAllowsIdenticalNamedNetworkReuse() {
        let rule = VMModelFieldNetworkDevice.PortForwardingRule(
            transport: .tcp,
            externalPort: 2222,
            internalAddress: "192.168.73.10",
            internalPort: 22
        )
        let shared = VMModelFieldNetworkDevice(
            type: .VMNetShared,
            networkIdentifier: "shared-lab",
            ipv4Subnet: "192.168.73.0",
            ipv4SubnetMask: "255.255.255.0",
            portForwardingRules: [rule]
        )

        XCTAssertNil(VMModelFieldNetworkDevice.collectionValidationError(
            [shared, shared],
            vmnetEntitlementGranted: true,
            availableInterfaceNames: []
        ))
    }

    func testVMNetCollectionRejectsOverlappingSubnetsAcrossDifferentNetworks() {
        let shared = VMModelFieldNetworkDevice(
            type: .VMNetShared,
            networkIdentifier: "shared-lab",
            ipv4Subnet: "192.168.72.0",
            ipv4SubnetMask: "255.255.254.0"
        )
        let hostOnly = VMModelFieldNetworkDevice(
            type: .VMNetHost,
            networkIdentifier: "host-lab",
            ipv4Subnet: "192.168.73.0",
            ipv4SubnetMask: "255.255.255.0"
        )

        let error = VMModelFieldNetworkDevice.collectionValidationError(
            [shared, hostOnly],
            vmnetEntitlementGranted: true,
            availableInterfaceNames: []
        )

        XCTAssertTrue(error?.contains("overlaps 192.168.72.0/255.255.254.0") == true)
        XCTAssertTrue(error?.contains("non-overlapping subnets") == true)
    }

    func testVMNetCollectionAllowsAdjacentNonOverlappingSubnets() {
        let first = VMModelFieldNetworkDevice(
            type: .VMNetShared,
            networkIdentifier: "first",
            ipv4Subnet: "192.168.72.0",
            ipv4SubnetMask: "255.255.255.0"
        )
        let second = VMModelFieldNetworkDevice(
            type: .VMNetHost,
            networkIdentifier: "second",
            ipv4Subnet: "192.168.73.0",
            ipv4SubnetMask: "255.255.255.0"
        )

        XCTAssertNil(VMModelFieldNetworkDevice.collectionValidationError(
            [first, second],
            vmnetEntitlementGranted: true,
            availableInterfaceNames: []
        ))
    }

    func testVMNetCollectionPreflightReportsOccupiedHostPortBeforeCreation() {
        let rule = VMModelFieldNetworkDevice.PortForwardingRule(
            transport: .tcp,
            externalPort: 2222,
            internalAddress: "192.168.73.10",
            internalPort: 22
        )
        let model = VMModelFieldNetworkDevice(
            type: .VMNetShared,
            ipv4Subnet: "192.168.73.0",
            ipv4SubnetMask: "255.255.255.0",
            portForwardingRules: [rule]
        )
        var probes: [(VMModelFieldNetworkDevice.PortForwardingRule.Transport, UInt16)] = []

        let error = VMModelFieldNetworkDevice.collectionValidationError(
            [model],
            vmnetEntitlementGranted: true,
            availableInterfaceNames: [],
            hostPortAvailability: { transport, port in
                probes.append((transport, port))
                return .occupied
            }
        )

        XCTAssertEqual(probes.count, 1)
        XCTAssertEqual(probes.first?.0, .tcp)
        XCTAssertEqual(probes.first?.1, 2222)
        XCTAssertTrue(error?.contains("TCP port 2222 is already in use") == true)
    }

    func testVMNetCollectionPreflightExplainsIndeterminateHostPortProbe() {
        let rule = VMModelFieldNetworkDevice.PortForwardingRule(
            transport: .udp,
            externalPort: 5353,
            internalAddress: "192.168.73.10",
            internalPort: 5353
        )
        let model = VMModelFieldNetworkDevice(type: .VMNetShared, portForwardingRules: [rule])

        let error = VMModelFieldNetworkDevice.collectionValidationError(
            [model],
            vmnetEntitlementGranted: true,
            availableInterfaceNames: [],
            hostPortAvailability: { _, _ in .unavailable("Permission denied") }
        )

        XCTAssertTrue(error?.contains("could not verify external UDP port 5353") == true)
        XCTAssertTrue(error?.contains("Permission denied") == true)
    }

    func testVMNetCollectionPreflightDoesNotProbeUntilStructuralValidationPasses() {
        let invalidRule = VMModelFieldNetworkDevice.PortForwardingRule(
            transport: .tcp,
            externalPort: 2222,
            internalAddress: "192.168.73.10",
            internalPort: 0
        )
        let model = VMModelFieldNetworkDevice(type: .VMNetShared, portForwardingRules: [invalidRule])
        var probeCount = 0

        let error = VMModelFieldNetworkDevice.collectionValidationError(
            [model],
            vmnetEntitlementGranted: true,
            availableInterfaceNames: [],
            hostPortAvailability: { _, _ in
                probeCount += 1
                return .available
            }
        )

        XCTAssertEqual(probeCount, 0)
        XCTAssertEqual(error, "VMNet port-forwarding ports must be between 1 and 65535.")
    }

    func testVMNetCollectionPreflightProbesAnIdenticalNamedEndpointOnce() {
        let rule = VMModelFieldNetworkDevice.PortForwardingRule(
            transport: .tcp,
            externalPort: 2222,
            internalAddress: "192.168.73.10",
            internalPort: 22
        )
        let first = VMModelFieldNetworkDevice(
            type: .VMNetShared,
            networkIdentifier: "development",
            portForwardingRules: [rule]
        )
        let second = VMModelFieldNetworkDevice(
            type: .VMNetShared,
            networkIdentifier: "development",
            portForwardingRules: [rule]
        )
        var probes: [(VMModelFieldNetworkDevice.PortForwardingRule.Transport, UInt16)] = []

        let error = VMModelFieldNetworkDevice.collectionValidationError(
            [first, second],
            vmnetEntitlementGranted: true,
            availableInterfaceNames: [],
            hostPortAvailability: { transport, port in
                probes.append((transport, port))
                return .available
            }
        )

        XCTAssertNil(error)
        XCTAssertEqual(probes.count, 1)
        XCTAssertEqual(probes.first?.0, .tcp)
        XCTAssertEqual(probes.first?.1, 2222)
    }

    func testHostPortProbeDetectsRealTCPOccupationAndKeepsUDPIndependent() throws {
        let reservation = try reserveLoopbackPort(transport: .tcp)
        defer { close(reservation.descriptor) }

        XCTAssertEqual(
            VMHostPortProbe.availability(transport: .tcp, port: reservation.port),
            .occupied
        )
        XCTAssertEqual(
            VMHostPortProbe.availability(transport: .udp, port: reservation.port),
            .available
        )
    }

    func testHostPortProbeReleasesSuccessfulAvailabilityCheck() throws {
        let reservation = try reserveLoopbackPort(transport: .udp)
        let port = reservation.port
        close(reservation.descriptor)

        XCTAssertEqual(VMHostPortProbe.availability(transport: .udp, port: port), .available)
        let secondReservation = try reservePort(transport: .udp, port: port)
        close(secondReservation)
    }

    func testNetworkModeCardsExposeDistinctOutcomeOrientedCopy() {
        let modes = VMModelFieldNetworkDevice.DeviceType.userSelectableCases

        XCTAssertEqual(modes, [.NAT, .VMNetShared, .VMNetHost])
        XCTAssertEqual(Set(modes.map(\.shortDisplayName)).count, modes.count)
        XCTAssertTrue(modes.allSatisfy { !$0.outcomeDescription.isEmpty })
        XCTAssertTrue(modes.allSatisfy { !$0.reachabilitySummary.isEmpty })
        XCTAssertFalse(VMModelFieldNetworkDevice.DeviceType.NAT.usesVMNet)
        XCTAssertTrue(VMModelFieldNetworkDevice.DeviceType.VMNetShared.usesVMNet)
        XCTAssertTrue(VMModelFieldNetworkDevice.DeviceType.VMNetHost.usesVMNet)
    }

    func testNATDraftDropsHiddenVMNetFields() {
        let draft = VMNetworkDeviceDraft(
            type: .NAT,
            networkIdentifier: "unused",
            ipv4Subnet: "192.168.70.0",
            ipv4SubnetMask: "255.255.255.0",
            externalInterface: "en0",
            mtu: "invalid",
            portForwardingRules: []
        )

        guard case let .success(model) = draft.build(vmnetEntitlementGranted: false) else {
            return XCTFail("NAT must not depend on VMNet-only draft fields or entitlement")
        }
        XCTAssertEqual(model.type, .NAT)
        XCTAssertNil(model.networkIdentifier)
        XCTAssertNil(model.ipv4Subnet)
        XCTAssertNil(model.mtu)
    }

    func testHostOnlyDraftDropsSharedOnlyFields() {
        let rule = VMModelFieldNetworkDevice.PortForwardingRule(
            transport: .tcp,
            externalPort: 2222,
            internalAddress: "192.168.70.10",
            internalPort: 22
        )
        let draft = VMNetworkDeviceDraft(
            type: .VMNetHost,
            networkIdentifier: "private-lab",
            ipv4Subnet: "192.168.70.0",
            ipv4SubnetMask: "255.255.255.0",
            externalInterface: "en0",
            mtu: "1500",
            portForwardingRules: [rule]
        )

        guard case let .success(model) = draft.build(vmnetEntitlementGranted: true) else {
            return XCTFail("A valid host-only draft should build")
        }
        XCTAssertEqual(model.type, .VMNetHost)
        XCTAssertNil(model.externalInterface)
        XCTAssertTrue(model.portForwardingRules.isEmpty)
        XCTAssertTrue(model.configurationSummary.contains("private-lab"))
    }

    func testSharedDraftPreservesAdvancedFieldsAndValidatesMTU() {
        var draft = VMNetworkDeviceDraft(type: .VMNetShared)
        draft.networkIdentifier = "shared-lab"
        draft.externalInterface = "en0"
        draft.mtu = "not-a-number"
        guard case let .failure(error) = draft.build(vmnetEntitlementGranted: true) else {
            return XCTFail("An invalid MTU must fail before a device is added")
        }
        XCTAssertTrue(error.contains("MTU"))

        draft.mtu = "1500"
        guard case let .success(model) = draft.build(vmnetEntitlementGranted: true) else {
            return XCTFail("The corrected shared draft should build")
        }
        XCTAssertEqual(model.networkIdentifier, "shared-lab")
        XCTAssertEqual(model.externalInterface, "en0")
        XCTAssertEqual(model.mtu, 1500)
    }

    private func reserveLoopbackPort(
        transport: VMModelFieldNetworkDevice.PortForwardingRule.Transport
    ) throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = try reservePort(transport: transport, port: 0)
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard status == 0 else {
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return (descriptor, UInt16(bigEndian: address.sin_port))
    }

    private func reservePort(
        transport: VMModelFieldNetworkDevice.PortForwardingRule.Transport,
        port: UInt16
    ) throws -> Int32 {
        let type = transport == .tcp ? SOCK_STREAM : SOCK_DGRAM
        let descriptor = socket(AF_INET, type, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0 else {
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return descriptor
    }
}
#endif
