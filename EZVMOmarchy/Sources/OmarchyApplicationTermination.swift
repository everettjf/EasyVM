import AppKit
import Virtualization

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

    private var machine: VZVirtualMachine?
    private var pending = false
    private var stopping = false
    private var timeout: DispatchWorkItem?

    func register(_ machine: VZVirtualMachine) {
        self.machine = machine
        stopping = false
    }

    func unregister(_ machine: VZVirtualMachine) {
        guard self.machine === machine else { return }
        self.machine = nil
        stopping = false
        if pending { finishTermination() }
    }

    func stopForViewTeardown(_ machine: VZVirtualMachine) {
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

    private func beginStopping(_ machine: VZVirtualMachine) {
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

    func machineDidStop(_ machine: VZVirtualMachine) {
        unregister(machine)
    }

    private func scheduleForcedStop(_ machine: VZVirtualMachine) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self, weak machine] in
            guard let self, let machine, self.pending, self.machine === machine else { return }
            self.forceStop(machine)
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private func forceStop(_ machine: VZVirtualMachine) {
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
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
