import Foundation

/// Holds the first error raised on the audio thread so the UI can pick it up.
nonisolated final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    private var failed = false

    var hasFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    func record(_ newError: Error) {
        lock.lock()
        if !failed {
            error = newError
            failed = true
        }
        lock.unlock()
    }

    /// Returns the recorded error once; later calls return nil.
    func take() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        let result = error
        error = nil
        return result
    }

    func reset() {
        lock.lock()
        error = nil
        failed = false
        lock.unlock()
    }
}
