import EZVMCore
import Foundation

struct OmarchyIntegrationObservation: Codable, Equatable {
    let schemaVersion: Int
    let observedAt: Date
    let sourceRevision: String
    let workspaceCreatedAt: Date?
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
    let fileImportPassed: Bool
    let fileImportObservedAt: Date?
    let importedFileSHA256: String?
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
    static let commandSuperFileName = "command-super.json"
    static let fullScreenFileName = "full-screen.json"
    static let desktopNotificationFileName = "desktop-notification.json"
    static let soakHeartbeatFileName = "soak-heartbeat.json"

    private struct CommandSuperObservation: Codable {
        let schemaVersion: Int
        let observedAt: Date
        let sourceRevision: String
        let eventTapEnabled: Bool
        let commandSpaceKeyDownAndUpCaptured: Bool
        let applicationActiveAfterCapture: Bool
        let virtualMachineWindowKeyAfterCapture: Bool
    }

    private struct SoakHeartbeat: Codable {
        let schemaVersion: Int
        let observedAt: Date
        let sourceRevision: String
        let guestAgentVersion: String
        let agentInstanceID: String?
        let bootID: String
        let uptimeSeconds: UInt64
        let desktopSessionActive: Bool
        let provisioningPending: Bool
    }

    private struct FullScreenObservation: Codable {
        let schemaVersion: Int
        let observedAt: Date
        let sourceRevision: String
        let enteredAt: Date?
        let exitedAt: Date?
        let enteredAndExitedFullScreen: Bool
        let applicationActiveAfterExit: Bool
        let virtualMachineWindowKeyAfterExit: Bool
        let virtualMachineViewFocusedAfterExit: Bool
    }

    private struct DesktopNotificationObservation: Codable {
        let schemaVersion: Int
        let observedAt: Date
        let sourceRevision: String
        let guestBootID: String
        let guestNotificationID: String
        let notificationTitle: String
        let macOSRequestAccepted: Bool
    }

    static func reportDesktopNotificationIfEnabled(
        _ notification: VMOmarchyDesktopNotification,
        guestBootID: String,
        layout: VMOmarchyWorkspaceLayout,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:],
        observedAt: Date = Date()
    ) {
        guard environment[OmarchyWorkspaceConfiguration.acceptanceEnabledKey] == "1" else { return }
        let observation = DesktopNotificationObservation(
            schemaVersion: 1,
            observedAt: observedAt,
            sourceRevision: bundleInfo["EZVMSourceRevision"] as? String ?? "",
            guestBootID: guestBootID,
            guestNotificationID: notification.id,
            notificationTitle: notification.title,
            macOSRequestAccepted: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: layout.diagnostics, withIntermediateDirectories: true)
            try encoder.encode(observation).write(
                to: layout.diagnostics.appending(path: desktopNotificationFileName),
                options: .atomic
            )
        } catch {
            NSLog("Could not write Omarchy notification observation: %@", error.localizedDescription)
        }
    }

    static func reportFullScreenIfEnabled(
        layout: VMOmarchyWorkspaceLayout,
        enteredAt: Date?,
        exitedAt: Date?,
        applicationActive: Bool,
        virtualMachineWindowKey: Bool,
        virtualMachineViewFocused: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:],
        observedAt: Date = Date()
    ) {
        guard environment[OmarchyWorkspaceConfiguration.acceptanceEnabledKey] == "1" else { return }
        let observation = FullScreenObservation(
            schemaVersion: 1,
            observedAt: observedAt,
            sourceRevision: bundleInfo["EZVMSourceRevision"] as? String ?? "",
            enteredAt: enteredAt,
            exitedAt: exitedAt,
            enteredAndExitedFullScreen: enteredAt != nil && exitedAt != nil,
            applicationActiveAfterExit: applicationActive,
            virtualMachineWindowKeyAfterExit: virtualMachineWindowKey,
            virtualMachineViewFocusedAfterExit: virtualMachineViewFocused
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: layout.diagnostics, withIntermediateDirectories: true)
            try encoder.encode(observation).write(
                to: layout.diagnostics.appending(path: fullScreenFileName),
                options: .atomic
            )
        } catch {
            NSLog("Could not write Omarchy full-screen observation: %@", error.localizedDescription)
        }
    }

    enum VirtualMachineEvent {
        case pauseRequested
        case paused
        case resumed
    }

    enum HostPowerEvent {
        case willSleep
        case didWake
    }

    enum RecoveryEvent {
        case agentRestartRequested(VMOmarchyGuestStatus)
        case disconnectedAfterAgentRestart
        case guestRestartRequested(VMOmarchyGuestStatus)
        case disconnectedAfterGuestRestart
        case guestInteractiveAfterRestart(VMOmarchyGuestStatus)
    }

    static func reportCommandSuperIfEnabled(
        layout: VMOmarchyWorkspaceLayout,
        applicationActive: Bool,
        virtualMachineWindowKey: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:],
        observedAt: Date = Date()
    ) {
        guard environment[OmarchyWorkspaceConfiguration.acceptanceEnabledKey] == "1" else { return }
        let observation = CommandSuperObservation(
            schemaVersion: 1,
            observedAt: observedAt,
            sourceRevision: bundleInfo["EZVMSourceRevision"] as? String ?? "",
            eventTapEnabled: true,
            commandSpaceKeyDownAndUpCaptured: true,
            applicationActiveAfterCapture: applicationActive,
            virtualMachineWindowKeyAfterCapture: virtualMachineWindowKey
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: layout.diagnostics, withIntermediateDirectories: true)
            try encoder.encode(observation).write(
                to: layout.diagnostics.appending(path: commandSuperFileName),
                options: .atomic
            )
        } catch {
            NSLog("Could not write Omarchy Command/Super observation: %@", error.localizedDescription)
        }
    }

    private struct LifecycleObservation: Codable {
        let schemaVersion: Int
        let sourceRevision: String
        var firstProvisioningPendingObservedAt: Date?
        var firstLockedObservedAt: Date?
        var firstActiveObservedAt: Date?
        var firstActiveAfterLockedObservedAt: Date?
        var firstPauseRequestedAt: Date?
        var firstPausedAt: Date?
        var firstResumedAt: Date?
        var firstActiveAfterResumeObservedAt: Date?
        var firstAgentRestartRequestedAt: Date?
        var firstAgentDisconnectedAfterRestartAt: Date?
        var firstAgentRecoveredAt: Date?
        var agentBootIDBeforeRestart: String?
        var agentBootIDAfterRestart: String?
        var agentInstanceIDBeforeRestart: String?
        var agentInstanceIDAfterRestart: String?
        var firstGuestRestartRequestedAt: Date?
        var firstGuestDisconnectedAfterRestartAt: Date?
        var firstGuestRecoveredAt: Date?
        var guestBootIDBeforeRestart: String?
        var guestBootIDAfterRestart: String?
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
        bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:],
        observedAt: Date = Date()
    ) {
        guard environment[OmarchyWorkspaceConfiguration.acceptanceEnabledKey] == "1" else { return }
        reportSoakHeartbeat(
            status: status,
            layout: layout,
            sourceRevision: bundleInfo["EZVMSourceRevision"] as? String ?? "",
            observedAt: observedAt
        )
        let file = layout.diagnostics.appending(path: lifecycleFileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var observation = (try? Data(contentsOf: file)).flatMap {
            try? decoder.decode(LifecycleObservation.self, from: $0)
        }.flatMap {
            $0.schemaVersion == 6
                && $0.sourceRevision == (bundleInfo["EZVMSourceRevision"] as? String ?? "")
                ? $0 : nil
        } ?? LifecycleObservation(
            schemaVersion: 6,
            sourceRevision: bundleInfo["EZVMSourceRevision"] as? String ?? "",
            firstProvisioningPendingObservedAt: nil,
            firstLockedObservedAt: nil,
            firstActiveObservedAt: nil,
            firstActiveAfterLockedObservedAt: nil,
            firstPauseRequestedAt: nil,
            firstPausedAt: nil,
            firstResumedAt: nil,
            firstActiveAfterResumeObservedAt: nil,
            firstAgentRestartRequestedAt: nil,
            firstAgentDisconnectedAfterRestartAt: nil,
            firstAgentRecoveredAt: nil,
            agentBootIDBeforeRestart: nil,
            agentBootIDAfterRestart: nil,
            agentInstanceIDBeforeRestart: nil,
            agentInstanceIDAfterRestart: nil,
            firstGuestRestartRequestedAt: nil,
            firstGuestDisconnectedAfterRestartAt: nil,
            firstGuestRecoveredAt: nil,
            guestBootIDBeforeRestart: nil,
            guestBootIDAfterRestart: nil,
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
        let interactiveDesktopReady = OmarchyInteractiveDesktopReadiness.isReady(status)
        if interactiveDesktopReady {
            observation.firstActiveObservedAt = observation.firstActiveObservedAt ?? observedAt
            if observation.firstLockedObservedAt != nil {
                observation.firstActiveAfterLockedObservedAt =
                    observation.firstActiveAfterLockedObservedAt ?? observedAt
            }
            if observation.firstResumedAt != nil {
                observation.firstActiveAfterResumeObservedAt =
                    observation.firstActiveAfterResumeObservedAt ?? observedAt
            }
            if observation.firstAgentDisconnectedAfterRestartAt != nil,
               observation.firstAgentRecoveredAt == nil,
               status.bootID == observation.agentBootIDBeforeRestart,
               let currentInstanceID = status.agentInstanceID,
               currentInstanceID != observation.agentInstanceIDBeforeRestart {
                observation.firstAgentRecoveredAt = observedAt
                observation.agentBootIDAfterRestart = status.bootID
                observation.agentInstanceIDAfterRestart = currentInstanceID
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

    static func reportLockCycleIfEnabled(
        layout: VMOmarchyWorkspaceLayout,
        lockedAt: Date,
        activeAt: Date,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard environment[OmarchyWorkspaceConfiguration.acceptanceEnabledKey] == "1" else { return }
        let file = layout.diagnostics.appending(path: lifecycleFileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var observation = (try? Data(contentsOf: file)).flatMap({
            try? decoder.decode(LifecycleObservation.self, from: $0)
        }), observation.schemaVersion == 6 else {
            NSLog("Cannot record Omarchy lock cycle before a Guest Agent status observation.")
            return
        }
        observation.firstLockedObservedAt = observation.firstLockedObservedAt ?? lockedAt
        observation.firstActiveAfterLockedObservedAt =
            observation.firstActiveAfterLockedObservedAt ?? activeAt
        observation.lastObservedAt = max(observation.lastObservedAt, activeAt)
        observation.lastDesktopSessionActive = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(observation).write(to: file, options: .atomic)
        } catch {
            NSLog("Could not write Omarchy lock cycle: %@", error.localizedDescription)
        }
    }

    private static func reportSoakHeartbeat(
        status: VMOmarchyGuestStatus,
        layout: VMOmarchyWorkspaceLayout,
        sourceRevision: String,
        observedAt: Date
    ) {
        let heartbeat = SoakHeartbeat(
            schemaVersion: 1,
            observedAt: observedAt,
            sourceRevision: sourceRevision,
            guestAgentVersion: status.agentVersion,
            agentInstanceID: status.agentInstanceID,
            bootID: status.bootID,
            uptimeSeconds: status.uptimeSeconds,
            desktopSessionActive: status.desktopSessionActive,
            provisioningPending: status.provisioningPending
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: layout.diagnostics, withIntermediateDirectories: true)
            try encoder.encode(heartbeat).write(
                to: layout.diagnostics.appending(path: soakHeartbeatFileName),
                options: .atomic
            )
        } catch {
            NSLog("Could not write Omarchy soak heartbeat: %@", error.localizedDescription)
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
        }), observation.schemaVersion == 6 else {
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
        }), observation.schemaVersion == 6 else {
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

    static func reportInteractiveAfterHostWakeIfEnabled(
        status: VMOmarchyGuestStatus,
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
        }), observation.schemaVersion == 6,
              observation.firstHostWakeObservedAt != nil,
              !status.bootID.isEmpty else {
            NSLog("Cannot record interactive Omarchy host wake before its power event.")
            return
        }
        observation.firstActiveAfterHostWakeObservedAt =
            observation.firstActiveAfterHostWakeObservedAt ?? observedAt
        observation.lastObservedAt = observedAt
        observation.lastDesktopSessionActive = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(observation).write(to: file, options: .atomic)
        } catch {
            NSLog("Could not write interactive Omarchy host wake: %@", error.localizedDescription)
        }
    }

    static func reportRecoveryEventIfEnabled(
        _ event: RecoveryEvent,
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
        }), observation.schemaVersion == 6 else {
            NSLog("Cannot record Omarchy recovery event before a Guest Agent status observation.")
            return
        }
        switch event {
        case .agentRestartRequested(let status):
            observation.firstAgentRestartRequestedAt = observation.firstAgentRestartRequestedAt ?? observedAt
            observation.agentBootIDBeforeRestart = observation.agentBootIDBeforeRestart ?? status.bootID
            observation.agentInstanceIDBeforeRestart =
                observation.agentInstanceIDBeforeRestart ?? status.agentInstanceID
        case .disconnectedAfterAgentRestart:
            observation.firstAgentDisconnectedAfterRestartAt =
                observation.firstAgentDisconnectedAfterRestartAt ?? observedAt
        case .guestRestartRequested(let status):
            observation.firstGuestRestartRequestedAt = observation.firstGuestRestartRequestedAt ?? observedAt
            observation.guestBootIDBeforeRestart = observation.guestBootIDBeforeRestart ?? status.bootID
        case .disconnectedAfterGuestRestart:
            observation.firstGuestDisconnectedAfterRestartAt =
                observation.firstGuestDisconnectedAfterRestartAt ?? observedAt
        case .guestInteractiveAfterRestart(let status):
            guard observation.firstGuestDisconnectedAfterRestartAt != nil,
                  !status.bootID.isEmpty,
                  status.bootID != observation.guestBootIDBeforeRestart else { return }
            observation.firstGuestRecoveredAt = observation.firstGuestRecoveredAt ?? observedAt
            observation.guestBootIDAfterRestart = observation.guestBootIDAfterRestart ?? status.bootID
        }
        observation.lastObservedAt = observedAt
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(observation).write(to: file, options: .atomic)
        } catch {
            NSLog("Could not write Omarchy recovery event: %@", error.localizedDescription)
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
            workspaceCreatedAt: metadata?.createdAt,
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
        workspaceCreatedAt: Date?,
        factoryImageVersion: String?,
        sourceRevision: String,
        sharedFolderRoundTrip: VMOmarchySharedFolderRoundTrip?,
        clipboardRoundTrip: OmarchyClipboardRoundTrip?,
        dynamicDisplayRoundTrip: OmarchyDynamicDisplayRoundTrip?,
        observedAt: Date
    ) -> OmarchyIntegrationObservation {
        let capabilities = status.capabilities.union(
            clipboardRoundTrip?.advertisedCapabilities ?? []
        )
        return OmarchyIntegrationObservation(
            schemaVersion: 5,
            observedAt: observedAt,
            sourceRevision: sourceRevision,
            workspaceCreatedAt: workspaceCreatedAt,
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
            clipboardTextCapabilityAdvertised: capabilities.contains("clipboard-agent-text-v1")
                || capabilities.contains("clipboard-text-v1"),
            clipboardImageCapabilityAdvertised: capabilities.contains("clipboard-agent-image-v1")
                || capabilities.contains("clipboard-image-v1"),
            dynamicDisplayCapabilityAdvertised: capabilities.contains("dynamic-display-v1"),
            sharedFolderRoundTripPassed: sharedFolderRoundTrip != nil,
            sharedFolderRoundTripObservedAt: sharedFolderRoundTrip?.observedAt,
            hostToGuestSHA256: sharedFolderRoundTrip?.hostToGuestSHA256,
            guestToHostSHA256: sharedFolderRoundTrip?.guestToHostSHA256,
            fileImportPassed: sharedFolderRoundTrip != nil,
            fileImportObservedAt: sharedFolderRoundTrip?.fileImportObservedAt,
            importedFileSHA256: sharedFolderRoundTrip?.importedFileSHA256,
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
