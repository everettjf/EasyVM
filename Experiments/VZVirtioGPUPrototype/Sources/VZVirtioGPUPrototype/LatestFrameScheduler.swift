import Foundation

/// Serial-queue helper that bounds presentation work to one in-flight frame.
/// While that frame is being delivered, newer submissions replace the pending
/// frame so the display catches up instead of replaying stale frames.
final class LatestFrameScheduler<Frame> {
    typealias Delivery = (Frame, @escaping () -> Void) -> Void

    private let delivery: Delivery
    private var pending: Frame?
    private var isDelivering = false
    private var generation: UInt64 = 0

    private(set) var submittedCount: UInt64 = 0
    private(set) var deliveredCount: UInt64 = 0
    private(set) var coalescedCount: UInt64 = 0

    init(delivery: @escaping Delivery) {
        self.delivery = delivery
    }

    func submit(_ frame: Frame) {
        submittedCount &+= 1
        if isDelivering {
            if pending != nil { coalescedCount &+= 1 }
            pending = frame
            return
        }
        deliver(frame)
    }

    func cancel() {
        generation &+= 1
        pending = nil
        isDelivering = false
    }

    private func deliver(_ frame: Frame) {
        isDelivering = true
        deliveredCount &+= 1
        let deliveryGeneration = generation
        delivery(frame) { [weak self] in
            guard let self, self.generation == deliveryGeneration else { return }
            if let next = self.pending {
                self.pending = nil
                self.deliver(next)
            } else {
                self.isDelivering = false
            }
        }
    }
}
