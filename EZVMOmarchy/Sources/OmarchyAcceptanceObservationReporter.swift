import EZVMCore
import Foundation

struct OmarchyIntegrationObservation: Codable, Equatable {
    let schemaVersion: Int
    let observedAt: Date
    let sourceRevision: String
    let factoryImageVersion: String?
    let omarchyRevision: String?
    let guestAgentVersion: String
    let guestHostName: String
    let guestAddresses: [String]
    let guestCapabilities: [String]
    let requiredCapabilities: [String]
    let desktopSessionActive: Bool
    let provisioningPending: Bool
    let sharedFolderCapabilityAdvertised: Bool
    let clipboardTextCapabilityAdvertised: Bool
    let clipboardImageCapabilityAdvertised: Bool
    let dynamicDisplayCapabilityAdvertised: Bool
    let sharedFolderRoundTripPassed: Bool
    let sharedFolderRoundTripObservedAt: Date?
    let hostToGuestSHA256: String?
    let guestToHostSHA256: String?
    let clipboardRoundTripPassed: Bool
    let clipboardRoundTripObservedAt: Date?
    let hostToGuestTextSHA256: String?
    let guestToHostTextSHA256: String?
    let hostToGuestImageSHA256: String?
    let guestToHostImageSHA256: String?
    let dynamicDisplayRoundTripPassed: Bool
    let dynamicDisplayRoundTripObservedAt: Date?
    let guestDisplayBefore: OmarchyDisplaySize?
    let guestDisplayAfter: OmarchyDisplaySize?
    let hostViewAfter: OmarchyDisplaySize?

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

enum OmarchyAcceptanceObservationReporter {
    static let fileName = "integration-readiness.json"
    static let lifecycleFileName = "integration-lifecycle.json"

    enum VirtualMachineEvent {
        case pauseRequested
        case paused
        case resumed
    }

    enum HostPowerEvent {
        case willSleep
        case didWake
    }

    private struct LifecycleObservation: Codable {
        let schemaVersion: Int
        var firstProvisioningPendingObservedAt: Date?
        var firstLockedObservedAt: Date?
        var firstActiveObservedAt: Date?
        var firstActiveAfterLockedObservedAt: Date?
        var firstPauseRequestedAt: Date?
        var firstPausedAt: Date?
        var firstResumedAt: Date?
        var firstActiveAfterResumeObservedAt: Date?
        var firstHostSleepObservedAt: Date?
        var firstHostWakeObservedAt: Date?
        var firstActiveAfterHostWakeObservedAt: Date?
        var lastObservedAt: Date
        var lastDesktopSessionActive: Bool
        var lastProvisioningPending: Bool
        var guestAgentVersion: String
    }

    static func reportLifecycleIfEnabled(
        status: VMOmarchyGuestStatus,
        layout: VMOmarchyWorkspaceLayout,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        observedAt: Date = Date()
    ) {
        guard environment[OmarchyWorkspaceConfiguration.acceptanceEnabledKey] == "1" else { return }
        let file = layout.diagnostics.appending(path: lifecycleFileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var observation = (try? Data(contentsOf: file)).flatMap {
            try? decoder.decode(LifecycleObservation.self, from: $0)
        }.flatMap { $0.schemaVersion == 4 ? $0 : nil } ?? LifecycleObservation(
            schemaVersion: 4,
            firstProvisioningPendingObservedAt: nil,
            firstLockedObservedAt: nil,
            firstActiveObservedAt: nil,
            firstActiveAfterLockedObservedAt: nil,
            firstPauseRequestedAt: nil,
            firstPausedAt: nil,
            firstResumedAt: nil,
            firstActiveAfterResumeObservedAt: nil,
            firstHostSleepObservedAt: nil,
            firstHostWakeObservedAt: nil,
            firstActiveAfterHostWakeObservedAt: nil,
            lastObservedAt: observedAt,
            lastDesktopSessionActive: status.desktopSessionActive,
            lastProvisioningPending: status.provisioningPending,
            guestAgentVersion: status.agentVersion
        )
        if status.provisioningPending {
            observation.firstProvisioningPendingObservedAt =
                observation.firstProvisioningPendingObservedAt ?? observedAt
        }
        if status.desktopSessionActive {
            observation.firstActiveObservedAt = observation.firstActiveObservedAt ?? observedAt
            if observation.firstLockedObservedAt != nil {
                observation.firstActiveAfterLockedObservedAt =
                    observation.firstActiveAfterLockedObservedAt ?? observedAt
            }
            if observation.firstResumedAt != nil {
                observation.firstActiveAfterResumeObservedAt =
                    observation.firstActiveAfterResumeObservedAt ?? observedAt
            }
            if observation.firstHostWakeObservedAt != nil {
                observation.firstActiveAfterHostWakeObservedAt =
                    observation.firstActiveAfterHostWakeObservedAt ?? observedAt
            }
        } else if !status.provisioningPending {
            observation.firstLockedObservedAt = observation.firstLockedObservedAt ?? observedAt
        }
        observation.lastObservedAt = observedAt
        observation.lastDesktopSessionActive = status.desktopSessionActive
        observation.lastProvisioningPending = status.provisioningPending
        observation.guestAgentVersion = status.agentVersion
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: layout.diagnostics, withIntermediateDirectories: true)
            try encoder.encode(observation).write(to: file, options: .atomic)
        } catch {
            NSLog("Could not write Omarchy integration lifecycle observation: %@", error.localizedDescription)
        }
    }

    static func reportVirtualMachineEventIfEnabled(
        _ event: VirtualMachineEvent,
        layout: VMOmarchyWorkspaceLayout,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        observedAt: Date = Date()
    ) {
        guard environment[OmarchyWorkspaceConfiguration.acceptanceEnabledKey] == "1" else { return }
        let file = layout.diagnostics.appending(path: lifecycleFileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var observation = (try? Data(contentsOf: file)).flatMap({
            try? decoder.decode(LifecycleObservation.self, from: $0)
        }), observation.schemaVersion == 4 else {
            NSLog("Cannot record Omarchy VM lifecycle event before a Guest Agent status observation.")
            return
        }
        switch event {
        case .pauseRequested:
            observation.firstPauseRequestedAt = observation.firstPauseRequestedAt ?? observedAt
        case .paused:
            observation.firstPausedAt = observation.firstPausedAt ?? observedAt
        case .resumed:
            observation.firstResumedAt = observation.firstResumedAt ?? observedAt
        }
        observation.lastObservedAt = observedAt
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(observation).write(to: file, options: .atomic)
        } catch {
            NSLog("Could not write Omarchy VM lifecycle event: %@", error.localizedDescription)
        }
    }

    static func reportHostPowerEventIfEnabled(
        _ event: HostPowerEvent,
        layout: VMOmarchyWorkspaceLayout,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        observedAt: Date = Date()
    ) {
        guard environment[OmarchyWorkspaceConfiguration.acceptanceEnabledKey] == "1" else { return }
        let file = layout.diagnostics.appending(path: lifecycleFileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var observation = (try? Data(contentsOf: file)).flatMap({
            try? decoder.decode(LifecycleObservation.self, from: $0)
        }), observation.schemaVersion == 4 else {
            NSLog("Cannot record Omarchy host power event before a Guest Agent status observation.")
            return
        }
        switch event {
        case .willSleep:
            observation.firstHostSleepObservedAt = observation.firstHostSleepObservedAt ?? observedAt
        case .didWake:
            observation.firstHostWakeObservedAt = observation.firstHostWakeObservedAt ?? observedAt
        }
        observation.lastObservedAt = observedAt
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(observation).write(to: file, options: .atomic)
        } catch {
            NSLog("Could not write Omarchy host power event: %@", error.localizedDescription)
        }
    }

    static func reportIfEnabled(
        status: VMOmarchyGuestStatus,
        requiredCapabilities: [String],
        layout: VMOmarchyWorkspaceLayout,
        sharedFolderRoundTrip: VMOmarchySharedFolderRoundTrip?,
        clipboardRoundTrip: OmarchyClipboardRoundTrip?,
        dynamicDisplayRoundTrip: OmarchyDynamicDisplayRoundTrip?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:],
        observedAt: Date = Date()
    ) {
        guard environment[OmarchyWorkspaceConfiguration.acceptanceEnabledKey] == "1" else { return }
        let assessment = VMOmarchyIntegrationAssessment.evaluate(
            status: status,
            requiredCapabilities: requiredCapabilities
        )
        guard assessment.isReady else { return }
        let metadata = try? VMOmarchyWorkspaceManager(layout: layout).metadata()
        let observation = makeObservation(
            status: status,
            requiredCapabilities: requiredCapabilities,
            factoryImageVersion: metadata?.factoryImageVersion,
            sourceRevision: bundleInfo["EZVMSourceRevision"] as? String ?? "",
            sharedFolderRoundTrip: sharedFolderRoundTrip,
            clipboardRoundTrip: clipboardRoundTrip,
            dynamicDisplayRoundTrip: dynamicDisplayRoundTrip,
            observedAt: observedAt
        )
        do {
            try FileManager.default.createDirectory(at: layout.diagnostics, withIntermediateDirectories: true)
            try observation.encoded().write(
                to: layout.diagnostics.appending(path: fileName),
                options: .atomic
            )
        } catch {
            NSLog("Could not write Omarchy integration observation: %@", error.localizedDescription)
        }
    }

    static func makeObservation(
        status: VMOmarchyGuestStatus,
        requiredCapabilities: [String],
        factoryImageVersion: String?,
        sourceRevision: String,
        sharedFolderRoundTrip: VMOmarchySharedFolderRoundTrip?,
        clipboardRoundTrip: OmarchyClipboardRoundTrip?,
        dynamicDisplayRoundTrip: OmarchyDynamicDisplayRoundTrip?,
        observedAt: Date
    ) -> OmarchyIntegrationObservation {
        let capabilities = status.capabilities
        return OmarchyIntegrationObservation(
            schemaVersion: 4,
            observedAt: observedAt,
            sourceRevision: sourceRevision,
            factoryImageVersion: factoryImageVersion,
            omarchyRevision: status.omarchyRevision,
            guestAgentVersion: status.agentVersion,
            guestHostName: status.hostName,
            guestAddresses: status.addresses.sorted(),
            guestCapabilities: capabilities.sorted(),
            requiredCapabilities: requiredCapabilities.sorted(),
            desktopSessionActive: status.desktopSessionActive,
            provisioningPending: status.provisioningPending,
            sharedFolderCapabilityAdvertised: capabilities.contains("shared-folders-v1"),
            clipboardTextCapabilityAdvertised: capabilities.contains("clipboard-text-v1"),
            clipboardImageCapabilityAdvertised: capabilities.contains("clipboard-image-v1"),
            dynamicDisplayCapabilityAdvertised: capabilities.contains("dynamic-display-v1"),
            sharedFolderRoundTripPassed: sharedFolderRoundTrip != nil,
            sharedFolderRoundTripObservedAt: sharedFolderRoundTrip?.observedAt,
            hostToGuestSHA256: sharedFolderRoundTrip?.hostToGuestSHA256,
            guestToHostSHA256: sharedFolderRoundTrip?.guestToHostSHA256,
            clipboardRoundTripPassed: clipboardRoundTrip != nil,
            clipboardRoundTripObservedAt: clipboardRoundTrip?.observedAt,
            hostToGuestTextSHA256: clipboardRoundTrip?.hostToGuestTextSHA256,
            guestToHostTextSHA256: clipboardRoundTrip?.guestToHostTextSHA256,
            hostToGuestImageSHA256: clipboardRoundTrip?.hostToGuestImageSHA256,
            guestToHostImageSHA256: clipboardRoundTrip?.guestToHostImageSHA256,
            dynamicDisplayRoundTripPassed: dynamicDisplayRoundTrip != nil,
            dynamicDisplayRoundTripObservedAt: dynamicDisplayRoundTrip?.observedAt,
            guestDisplayBefore: dynamicDisplayRoundTrip?.guestBefore,
            guestDisplayAfter: dynamicDisplayRoundTrip?.guestAfter,
            hostViewAfter: dynamicDisplayRoundTrip?.hostViewAfter
        )
    }
}
