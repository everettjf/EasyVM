import EZVMCore

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
}
