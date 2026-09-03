import AppKit
import Virtualization

protocol OmarchyTerminableMachine: AnyObject {
    var canRequestStop: Bool { get }
    var canStop: Bool { get }
    func requestStop() throws
    func stop(completionHandler: @escaping (Error?) -> Void)
}

extension VZVirtualMachine: OmarchyTerminableMachine {}

final class OmarchyApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        OmarchyApplicationTerminationController.shared.requestTermination()
    }
}

@MainActor
final class OmarchyApplicationTerminationController {
    static let shared = OmarchyApplicationTerminationController()

    private var machine: OmarchyTerminableMachine?
    private var pending = false
    private var stopping = false
    private var timeout: DispatchWorkItem?
    private let reply: @MainActor (Bool) -> Void
    private let scheduleTimeout: @MainActor (DispatchWorkItem) -> Void

    init(
        reply: @escaping @MainActor (Bool) -> Void = {
            NSApp.reply(toApplicationShouldTerminate: $0)
        },
        scheduleTimeout: @escaping @MainActor (DispatchWorkItem) -> Void = {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: $0)
        }
    ) {
        self.reply = reply
        self.scheduleTimeout = scheduleTimeout
    }

    func register(_ machine: OmarchyTerminableMachine) {
        self.machine = machine
        stopping = false
    }

    func unregister(_ machine: OmarchyTerminableMachine) {
        guard self.machine === machine else { return }
        self.machine = nil
        stopping = false
        if pending { finishTermination() }
    }

    func stopForViewTeardown(_ machine: OmarchyTerminableMachine) {
        guard self.machine === machine, !stopping else { return }
        beginStopping(machine)
    }

    func requestTermination() -> NSApplication.TerminateReply {
        guard !pending, let machine else { return .terminateNow }
        pending = true
        if stopping { return .terminateLater }
        beginStopping(machine)
        return .terminateLater
    }

    private func beginStopping(_ machine: OmarchyTerminableMachine) {
        stopping = true
        if machine.canRequestStop {
            do {
                try machine.requestStop()
                scheduleForcedStop(machine)
                return
            } catch {
                NSLog("Could not request graceful Omarchy shutdown while quitting: %@", error.localizedDescription)
            }
        }
        guard machine.canStop else {
            self.machine = nil
            stopping = false
            finishTermination()
            return
        }
        forceStop(machine)
    }

    func machineDidStop(_ machine: OmarchyTerminableMachine) {
        unregister(machine)
    }

    private func scheduleForcedStop(_ machine: OmarchyTerminableMachine) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self, weak machine] in
            guard let self, let machine, self.pending, self.machine === machine else { return }
            self.forceStop(machine)
        }
        timeout = work
        scheduleTimeout(work)
    }

    private func forceStop(_ machine: OmarchyTerminableMachine) {
        timeout?.cancel()
        timeout = nil
        guard machine.canStop else {
            finishTermination()
            return
        }
        machine.stop { [weak self, weak machine] error in
            DispatchQueue.main.async {
                if let error {
                    NSLog("Could not force-stop Omarchy while quitting: %@", error.localizedDescription)
                }
                if let self, let machine, self.machine === machine {
                    self.machine = nil
                    self.stopping = false
                }
                self?.finishTermination()
            }
        }
    }

    private func finishTermination() {
        guard pending else { return }
        pending = false
        timeout?.cancel()
        timeout = nil
        reply(true)
    }
}
