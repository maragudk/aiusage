import Synchronization

extension UsageProvider {
    /// Fetches the limits, but gives up after `timeout` with `UsageError.timedOut`.
    ///
    /// This returns at the timeout even if the fetch ignores cancellation, for example because it is stuck
    /// in a blocking system call, so a stuck provider can never hold up a refresh. The fetch is cancelled,
    /// and its result is dropped if it arrives later.
    public func fetchLimits(timeout: Duration) async -> Result<[UsageLimit], UsageError> {
        let outcome = FirstOutcome<Result<[UsageLimit], UsageError>>()
        return await withCheckedContinuation { continuation in
            outcome.start(continuation)
            let fetch = Task {
                do throws(UsageError) {
                    outcome.finish(.success(try await fetchLimits()))
                } catch {
                    outcome.finish(.failure(error))
                }
            }
            let timer = Task {
                guard (try? await Task.sleep(for: timeout)) != nil else {
                    return
                }
                outcome.finish(.failure(.timedOut))
            }
            outcome.whenFinished(fetch.cancel)
            outcome.whenFinished(timer.cancel)
        }
    }
}

/// Resumes a continuation with whichever outcome comes first, and ignores the rest.
private final class FirstOutcome<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Never>?
        var cleanups: [@Sendable () -> Void] = []
        var isFinished = false
    }

    private let state = Mutex(State())

    func start(_ continuation: CheckedContinuation<Value, Never>) {
        state.withLock { $0.continuation = continuation }
    }

    /// Runs `cleanup` once there is an outcome, or right away if there already is one.
    func whenFinished(_ cleanup: @escaping @Sendable () -> Void) {
        let isFinished = state.withLock { state in
            if !state.isFinished {
                state.cleanups.append(cleanup)
            }
            return state.isFinished
        }
        if isFinished {
            cleanup()
        }
    }

    func finish(_ value: Value) {
        let (continuation, cleanups) = state.withLock { state in
            guard !state.isFinished else {
                return (CheckedContinuation<Value, Never>?.none, [@Sendable () -> Void]())
            }
            state.isFinished = true
            defer {
                state.continuation = nil
                state.cleanups = []
            }
            return (state.continuation, state.cleanups)
        }
        continuation?.resume(returning: value)
        for cleanup in cleanups {
            cleanup()
        }
    }
}
