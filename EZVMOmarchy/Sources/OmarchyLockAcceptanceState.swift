import EZVMCore

enum OmarchyInteractiveDesktopReadiness {
    // The system agent can report the compositor as active while the visible
    // session is still locked. Session-agent capabilities prove that the
    // authenticated user's desktop is reachable again.
    static let requiredSessionCapabilities: Set<String> = [
        "clipboard-agent-text-v1",
        "clipboard-agent-image-v1",
    ]

    static func isReady(_ status: VMOmarchyGuestStatus) -> Bool {
        status.desktopSessionActive
            && requiredSessionCapabilities.isSubset(of: status.capabilities)
    }
}

enum OmarchyAgentRestartRecoveryReadiness {
    static func isReady(
        baseline: VMOmarchyGuestStatus,
        recovered: VMOmarchyGuestStatus
    ) -> Bool {
        recovered.bootID == baseline.bootID
            && recovered.agentInstanceID?.isEmpty == false
            && recovered.agentInstanceID != baseline.agentInstanceID
            && !recovered.provisioningPending
            && OmarchyInteractiveDesktopReadiness.isReady(recovered)
    }
}

struct OmarchyAcceptanceUnlockCredential: Equatable {
    let password: String

    init?(environment: [String: String]) {
        guard environment[OmarchyWorkspaceConfiguration.acceptanceEnabledKey] == "1",
              let password = environment[OmarchyWorkspaceConfiguration.acceptanceUnlockPasswordKey],
              (1...128).contains(password.utf8.count),
              password.unicodeScalars.allSatisfy({ (0x20...0x7e).contains($0.value) }) else {
            return nil
        }
        self.password = password
    }
}

struct OmarchyLockAcceptanceState: Equatable {
    enum Phase: Equatable {
        case idle
        case inFlight
        case complete
    }

    private(set) var phase: Phase = .idle

    mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .inFlight
        return true
    }

    mutating func completeObservedCycle() -> Bool {
        guard phase == .inFlight else { return false }
        phase = .complete
        return true
    }
}

/// Tracks the portion of lifecycle acceptance that begins after the Guest
/// restart request. A fresh boot can reconnect while Omarchy is still locked;
/// that is not a recovered desktop and must be unlocked before the probe can
/// complete.
struct OmarchyGuestRestartAcceptanceState: Equatable {
    enum Phase: Equatable {
        case idle
        case waitingForRestart(previousBootID: String)
        case waitingForInteractiveProof(bootID: String)
        case complete
    }

    enum Action: Equatable {
        case none
        case submitUnlockSecret
    }

    private(set) var phase: Phase = .idle

    mutating func begin(previousBootID: String) -> Bool {
        guard phase == .idle, !previousBootID.isEmpty else { return false }
        phase = .waitingForRestart(previousBootID: previousBootID)
        return true
    }

    mutating func observe(_ status: VMOmarchyGuestStatus) -> Action {
        guard !status.provisioningPending, !status.bootID.isEmpty else { return .none }
        switch phase {
        case .waitingForRestart(let previousBootID) where status.bootID != previousBootID:
            // A freshly rebooted Omarchy can advertise its session Agent while
            // the secure lock surface is still visible. Never accept status
            // alone as interactive recovery; submit through the virtual USB
            // keyboard and require an actual desktop command round trip.
            phase = .waitingForInteractiveProof(bootID: status.bootID)
            return .submitUnlockSecret
        case .idle, .waitingForRestart, .waitingForInteractiveProof, .complete:
            return .none
        }
    }

    mutating func completeInteractiveProof(bootID: String) -> Bool {
        guard case .waitingForInteractiveProof(let expectedBootID) = phase,
              bootID == expectedBootID else { return false }
        phase = .complete
        return true
    }
}
