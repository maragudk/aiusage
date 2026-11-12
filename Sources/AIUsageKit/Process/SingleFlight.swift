import Synchronization

/// Runs at most one operation at a time. A caller that arrives while one is in flight waits for it and gets
/// its result, instead of starting another.
///
/// The Claude provider reads the Keychain through this, so two refreshes can never stack two Keychain prompts.
final class SingleFlight<Value: Sendable>: Sendable {
    private let current = Mutex<Task<Value, Never>?>(nil)

    func run(_ operation: @escaping @Sendable () async -> Value) async -> Value {
        let task = current.withLock { current in
            if let current {
                return current
            }
            let task = Task { await operation() }
            current = task
            return task
        }
        let value = await task.value
        current.withLock { current in
            if current == task {
                current = nil
            }
        }
        return value
    }
}
