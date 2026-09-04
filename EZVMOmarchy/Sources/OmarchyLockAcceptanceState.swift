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
        case waitingForLocked
        case waitingForActive
        case complete
    }

    enum Action: Equatable {
        case none
        case submitUnlockSecret
        case completed
    }

    private(set) var phase: Phase = .idle

    mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .waitingForLocked
        return true
    }

    mutating func observe(_ status: VMOmarchyGuestStatus) -> Action {
        guard !status.provisioningPending else { return .none }
        switch phase {
        case .waitingForLocked where !status.desktopSessionActive:
            phase = .waitingForActive
            return .submitUnlockSecret
        case .waitingForActive where status.desktopSessionActive:
            phase = .complete
            return .completed
        case .idle, .waitingForLocked, .waitingForActive, .complete:
            return .none
        }
    }

    mutating func timeout() -> Bool {
        switch phase {
        case .waitingForLocked, .waitingForActive:
            phase = .idle
            return true
        case .idle, .complete:
            return false
        }
    }

    mutating func completeObservedCycle() -> Bool {
        guard phase == .waitingForLocked else { return false }
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
        case waitingForActive(bootID: String)
        case complete
    }

    enum Action: Equatable {
        case none
        case submitUnlockSecret
        case completed
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
            if OmarchyInteractiveDesktopReadiness.isReady(status) {
                phase = .complete
                return .completed
            }
            phase = .waitingForActive(bootID: status.bootID)
            return .submitUnlockSecret
        case .waitingForActive(let bootID)
            where status.bootID == bootID && OmarchyInteractiveDesktopReadiness.isReady(status):
            phase = .complete
            return .completed
        case .idle, .waitingForRestart, .waitingForActive, .complete:
            return .none
        }
    }
}
