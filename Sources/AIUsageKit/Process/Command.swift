import Foundation
import Synchronization

/// How a command run by `Command.run` ended.
public enum CommandResult: Sendable, Equatable {
    /// The command exited by itself. `output` is everything it wrote to stdout.
    case exited(status: Int32, output: Data)
    /// The command didn't finish in time and was killed.
    case timedOut
    /// The command couldn't be started.
    case launchFailed
}

/// Runs a short command and collects its stdout, with a timeout.
enum Command {
    /// The signature of `run`, so callers can take a fake runner in tests.
    typealias Runner = @Sendable (_ executable: URL, _ arguments: [String], _ timeout: Duration) async -> CommandResult

    /// How long a command gets to exit after SIGTERM before it gets SIGKILL.
    static let killGrace: Duration = .seconds(1)

    /// Blocking work runs here, never on Swift's cooperative pool or the main actor. It's concurrent,
    /// so one stuck command can't hold up the next.
    private static let queue = DispatchQueue(label: "dk.maragu.aiusage.command", attributes: .concurrent)

    /// Runs `executable` with stdin closed and stderr discarded, and returns its stdout and exit status.
    ///
    /// If it runs longer than `timeout`, it gets SIGTERM, then SIGKILL, and the result is `.timedOut`.
    static func run(_ executable: URL, arguments: [String], timeout: Duration) async -> CommandResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: runBlocking(executable, arguments: arguments, timeout: timeout))
            }
        }
    }

    private static func runBlocking(_ executable: URL, arguments: [String], timeout: Duration) -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output

        do {
            try process.run()
        } catch {
            return .launchFailed
        }

        let didTimeOut = Mutex(false)
        let watchdog = DispatchWorkItem {
            guard process.isRunning else {
                return
            }
            didTimeOut.withLock { $0 = true }
            process.terminate()
            queue.asyncAfter(deadline: .now() + killGrace.timeInterval) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        queue.asyncAfter(deadline: .now() + timeout.timeInterval, execute: watchdog)

        // Reads until the command exits and closes stdout, or is killed.
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        watchdog.cancel()

        if didTimeOut.withLock({ $0 }) {
            return .timedOut
        }
        return .exited(status: process.terminationStatus, output: data)
    }
}

extension Duration {
    /// The duration in seconds, for Dispatch and Foundation APIs.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
