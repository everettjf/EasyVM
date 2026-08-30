import Foundation

private final class RendererResultBox<Value>: @unchecked Sendable {
    var value: Value?
}

final class RendererExecutor: @unchecked Sendable {
    private let condition = NSCondition()
    private let ready = DispatchSemaphore(value: 0)
    private var jobs: [() -> Void] = []
    private var stopping = false
    private var pollOperation: (() -> Void)?
    private var pollingEnabled = false
    private var thread: Thread!

    init() {
        thread = Thread { [unowned self] in run() }
        thread.name = "com.everettjf.ezvm.prototype.virgl-renderer"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func sync<Value>(_ operation: @escaping () -> Value) -> Value {
        if Thread.current === thread { return operation() }
        let completion = DispatchSemaphore(value: 0)
        let result = RendererResultBox<Value>()
        condition.lock()
        jobs.append {
            result.value = operation()
            completion.signal()
        }
        condition.signal()
        condition.unlock()
        completion.wait()
        return result.value!
    }

    func async(_ operation: @escaping () -> Void) {
        condition.lock()
        guard !stopping else {
            condition.unlock()
            return
        }
        jobs.append(operation)
        condition.signal()
        condition.unlock()
    }

    func configurePolling(_ operation: @escaping () -> Void) {
        condition.lock()
        pollOperation = operation
        condition.unlock()
    }

    func setPollingEnabled(_ enabled: Bool) {
        condition.lock()
        pollingEnabled = enabled
        condition.signal()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopping = true
        condition.signal()
        condition.unlock()
    }

    private func run() {
        ready.signal()
        while true {
            condition.lock()
            while jobs.isEmpty && !stopping {
                if pollingEnabled {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.001))
                    break
                }
                condition.wait()
            }
            if stopping && jobs.isEmpty {
                condition.unlock()
                return
            }
            let job = jobs.isEmpty ? nil : jobs.removeFirst()
            let poll = pollingEnabled ? pollOperation : nil
            condition.unlock()
            job?()
            poll?()
        }
    }
}
