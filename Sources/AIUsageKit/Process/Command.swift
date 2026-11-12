import Foundation

/// How a command run by `Command.run` ended.
public enum CommandResult: Sendable, Equatable {
    /// The command exited by itself before the deadline. `output` is what it wrote to stdout.
    case exited(status: Int32, output: Data)
    /// The command didn't exit before the deadline and was killed.
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

    private enum Event {
        case output(Data)
        case endOfOutput
        case exited(Int32)
        case deadline
    }

    /// Runs `executable` with stdin closed and stderr discarded, and returns its stdout and exit status.
    ///
    /// Nothing blocks a thread: the exit and the output arrive as events. The command counts as exited if it
    /// exits by itself before `timeout`. Its output is then whatever arrived before stdout closed, or before
    /// the deadline if a background child keeps stdout open. Otherwise it gets SIGTERM, then SIGKILL, and
    /// the result is `.timedOut`.
    static func run(_ executable: URL, arguments: [String], timeout: Duration) async -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output

        let (events, sink) = AsyncStream<Event>.makeStream()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                sink.yield(.endOfOutput)
            } else {
                sink.yield(.output(data))
            }
        }
        process.terminationHandler = { process in
            sink.yield(.exited(process.terminationStatus))
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            sink.finish()
        }

        do {
            try process.run()
        } catch {
            return .launchFailed
        }

        let deadline = yieldDeadline(after: timeout, to: sink)
        defer { deadline.cancel() }

        var data = Data()
        var status: Int32?
        var isOutputDone = false
        events: for await event in events {
            switch event {
            case .output(let chunk):
                data.append(chunk)
            case .endOfOutput:
                isOutputDone = true
            case .exited(let exitStatus):
                status = exitStatus
            case .deadline:
                break events
            }
            if status != nil, isOutputDone {
                break
            }
        }

        if let status {
            return .exited(status: status, output: data)
        }
        await kill(process, events: events, sink: sink)
        return .timedOut
    }

    /// Sends SIGTERM, then SIGKILL if the process hasn't exited after `killGrace`.
    private static func kill(_ process: Process, events: AsyncStream<Event>, sink: AsyncStream<Event>.Continuation) async {
        process.terminate()
        let grace = yieldDeadline(after: killGrace, to: sink)
        defer { grace.cancel() }
        events: for await event in events {
            switch event {
            case .exited:
                return
            case .deadline:
                break events
            case .output, .endOfOutput:
                continue
            }
        }
        // Foundation has no SIGKILL. `isRunning` stays true until Foundation has reaped the process,
        // so the identifier still belongs to it here.
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func yieldDeadline(after duration: Duration, to sink: AsyncStream<Event>.Continuation) -> Task<Void, Never> {
        Task {
            guard (try? await Task.sleep(for: duration)) != nil else {
                return
            }
            sink.yield(.deadline)
        }
    }
}
