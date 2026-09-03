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

    private struct LifecycleObservation: Codable {
        let schemaVersion: Int
        var firstInactiveObservedAt: Date?
        var firstActiveObservedAt: Date?
        var lastObservedAt: Date
        var lastDesktopSessionActive: Bool
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
        } ?? LifecycleObservation(
            schemaVersion: 1,
            firstInactiveObservedAt: nil,
            firstActiveObservedAt: nil,
            lastObservedAt: observedAt,
            lastDesktopSessionActive: status.desktopSessionActive,
            guestAgentVersion: status.agentVersion
        )
        if status.desktopSessionActive {
            observation.firstActiveObservedAt = observation.firstActiveObservedAt ?? observedAt
        } else {
            observation.firstInactiveObservedAt = observation.firstInactiveObservedAt ?? observedAt
        }
        observation.lastObservedAt = observedAt
        observation.lastDesktopSessionActive = status.desktopSessionActive
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
