import AppKit
import Foundation
import UserNotifications
import EZVMCore

enum OmarchyNotificationActivationPolicy {
    static func shouldRun(
        enabled: Bool,
        capabilities: Set<String>,
        desktopSessionActive: Bool,
        provisioningPending: Bool
    ) -> Bool {
        enabled
            && capabilities.contains("desktop-notifications-v1")
            && desktopSessionActive
            && !provisioningPending
    }
}

enum OmarchyNotificationPermissionAction: Equatable {
    case enable
    case request
    case openSystemSettings
}

enum OmarchyNotificationPermissionPolicy {
    static func action(for status: UNAuthorizationStatus) -> OmarchyNotificationPermissionAction {
        switch status {
        case .authorized, .provisional, .ephemeral: .enable
        case .notDetermined: .request
        case .denied: .openSystemSettings
        @unknown default: .openSystemSettings
        }
    }

    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.notifications"
    )!
}

@MainActor
final class OmarchyNotificationController {
    typealias Deliver = (UNNotificationRequest, @escaping @Sendable (Error?) -> Void) -> Void

    private let client: VMOmarchyGuestAgentClient
    private let bootID: String
    private let deliverRequest: Deliver
    private let deliverySucceeded: (VMOmarchyDesktopNotification) -> Void
    private var timer: Timer?
    private var polling = false
    private var deliveryState: OmarchyNotificationDeliveryState

    init(
        client: VMOmarchyGuestAgentClient,
        bootID: String,
        center: UNUserNotificationCenter = .current(),
        deliverySucceeded: @escaping (VMOmarchyDesktopNotification) -> Void = { _ in }
    ) {
        self.client = client
        self.bootID = bootID
        self.deliveryState = OmarchyNotificationDeliveryState(bootID: bootID)
        self.deliverySucceeded = deliverySucceeded
        self.deliverRequest = { request, completion in
            center.add(request, withCompletionHandler: completion)
        }
    }

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        polling = false
    }

    private func poll() {
        guard !polling else { return }
        polling = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { polling = false }
            guard let notifications = try? await client.currentDesktopNotifications() else { return }
            let pendingIDs = Set(deliveryState.pendingIDs(from: notifications.map(\.id)))
            for notification in notifications where pendingIDs.contains(notification.id) {
                deliver(notification)
            }
        }
    }

    private func deliver(_ notification: VMOmarchyDesktopNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body ?? ""
        content.subtitle = notification.app.flatMap { $0.isEmpty ? nil : $0 } ?? "Omarchy"
        content.sound = notification.urgency >= 2 ? .default : nil
        content.userInfo = ["ezvmOmarchyGuestNotification": true]
        let request = UNNotificationRequest(
            identifier: "ezvm-omarchy-\(bootID)-\(notification.id)",
            content: content,
            trigger: nil
        )
        deliverRequest(request) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.deliveryState.complete(notification.id, succeeded: error == nil)
                if let error {
                    NSLog("Could not mirror Omarchy notification: %@", error.localizedDescription)
                } else {
                    self.deliverySucceeded(notification)
                }
            }
        }
    }
}

struct OmarchyNotificationDeliveryState {
    private let bootID: String
    private var baselineEstablished = false
    private var seenOrder: [String] = []
    private var seen = Set<String>()
    private var inFlight = Set<String>()

    init(bootID: String) {
        self.bootID = bootID
    }

    mutating func pendingIDs(from guestIDs: [String]) -> [String] {
        guard baselineEstablished else {
            guestIDs.forEach { remember($0) }
            baselineEstablished = true
            return []
        }
        return guestIDs.filter { guestID in
            let identity = identity(for: guestID)
            return !seen.contains(identity) && inFlight.insert(identity).inserted
        }
    }

    mutating func complete(_ guestID: String, succeeded: Bool) {
        inFlight.remove(identity(for: guestID))
        if succeeded { remember(guestID) }
    }

    private func identity(for guestID: String) -> String { "\(bootID):\(guestID)" }

    private mutating func remember(_ guestID: String) {
        let identity = identity(for: guestID)
        guard seen.insert(identity).inserted else { return }
        seenOrder.append(identity)
        while seenOrder.count > 256 {
            seen.remove(seenOrder.removeFirst())
        }
    }
}
