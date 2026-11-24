import Foundation
import Synchronization

@testable import AIUsageKit

/// Answers each call with the next canned result and records the calls.
final class FakeRunner: Sendable {
    struct Call {
        let executable: URL
        let arguments: [String]
        let timeout: Duration
        var environment: [String: String]?
        var currentDirectory: URL?
    }

    private let state: Mutex<(results: [CommandResult], calls: [Call])>

    init(results: [CommandResult]) {
        state = Mutex((results: results, calls: []))
    }

    var calls: [Call] {
        state.withLock { $0.calls }
    }

    @Sendable
    func run(_ executable: URL, arguments: [String], timeout: Duration) async -> CommandResult {
        record(Call(executable: executable, arguments: arguments, timeout: timeout))
    }

    @Sendable
    func run(
        _ executable: URL,
        arguments: [String],
        timeout: Duration,
        environment: [String: String]?,
        currentDirectory: URL?
    ) async -> CommandResult {
        record(Call(executable: executable, arguments: arguments, timeout: timeout, environment: environment, currentDirectory: currentDirectory))
    }

    private func record(_ call: Call) -> CommandResult {
        state.withLock { state in
            state.calls.append(call)
            return state.results.isEmpty ? .launchFailed : state.results.removeFirst()
        }
    }
}
