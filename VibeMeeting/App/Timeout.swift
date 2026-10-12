import Foundation

/// Waits for `operation` for at most `seconds` and returns its value, or nil on
/// timeout. On timeout the operation keeps running in the background; this only
/// stops waiting for it. (A task group can't do this: it always waits for every
/// child, and awaiting a task's value ignores cancellation.)
func firstResult<T: Sendable>(within seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let gate = ResumeGate()
        Task {
            let value = await operation()
            if gate.claim() { continuation.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if gate.claim() { continuation.resume(returning: nil) }
        }
    }
}

/// Lets exactly one of several racers resume a continuation.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
