import Foundation

/// Lets the Codex CLI fix its own expired login. Only ever run on a user click.
///
/// 1. Starts `codex app-server` and sends `account/read` with `refreshToken: true`. Codex then refreshes
///    its stored token with its own single-use refresh token and writes `auth.json` itself. This doesn't
///    start a model turn, so it doesn't spend usage.
/// 2. If the token is still expired after that, for example because the refresh token has expired too,
///    it runs `codex login`, which opens the browser sign-in, and waits for it to exit.
///
/// The app never calls the OpenAI token endpoint and never writes `auth.json`.
/// Process output is discarded and never logged, because it can contain account details.
struct CodexLoginRepair: Sendable {
    let codex: URL
    let version: String
    /// Whether `auth.json` now holds a usable token.
    let isLoginValid: @Sendable () -> Bool
    var refreshTimeout: Duration = .seconds(30)
    var loginTimeout: Duration = .seconds(10 * 60)

    func run(progress: @escaping @Sendable (String) -> Void) async {
        progress("Asking Codex to refresh its login…")
        let didAnswer = await refreshThroughAppServer()
        let isValid = isLoginValid()
        Log.login.info("codex app-server refresh answered=\(didAnswer, privacy: .public) valid=\(isValid, privacy: .public)")
        guard !isValid else {
            return
        }

        progress("Finish signing in to Codex in your browser…")
        let status = await runLogin()
        Log.login.info("codex login exited status=\(status, privacy: .public)")
    }

    /// Asks a short-lived `codex app-server` to refresh the token. Returns whether it answered the request.
    private func refreshThroughAppServer() async -> Bool {
        let process = Process()
        process.executableURL = codex
        process.arguments = ["app-server"]
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = Self.exitStatus(of: process)

        do {
            try process.run()
        } catch {
            Log.login.error("could not start codex app-server")
            return false
        }

        let watchdog = Self.terminate(process, after: refreshTimeout)
        defer { watchdog.cancel() }

        let writer = input.fileHandleForWriting
        var didAnswer = false
        do {
            try Self.send(Self.initializeRequest(version: version), to: writer)
            for try await line in output.fileHandleForReading.bytes.lines {
                switch Self.responseID(in: line) {
                case 1:
                    try Self.send(#"{"method":"initialized"}"#, to: writer)
                    try Self.send(#"{"id":2,"method":"account/read","params":{"refreshToken":true}}"#, to: writer)
                case 2:
                    didAnswer = true
                default:
                    continue
                }
                if didAnswer {
                    break
                }
            }
        } catch {
            Log.login.error("codex app-server conversation failed")
        }

        // Closing stdin asks the app server to exit. Give it a moment to finish writing auth.json.
        try? writer.close()
        let grace = Self.terminate(process, after: .seconds(5))
        defer { grace.cancel() }
        _ = await exited.value
        return didAnswer
    }

    /// Runs `codex login`, which opens the browser sign-in, and returns its exit status.
    private func runLogin() async -> Int32 {
        let process = Process()
        process.executableURL = codex
        process.arguments = ["login"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = Self.exitStatus(of: process)
        do {
            try process.run()
        } catch {
            Log.login.error("could not start codex login")
            return -1
        }
        let watchdog = Self.terminate(process, after: loginTimeout)
        defer { watchdog.cancel() }
        return await exited.value
    }

    /// The app's environment with the CLI's directory and the usual system paths on `PATH`,
    /// since a GUI app doesn't get the shell's `PATH`.
    private var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let paths = [codex.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = (paths + [environment["PATH"]].compactMap(\.self)).joined(separator: ":")
        return environment
    }

    static func initializeRequest(version: String) -> String {
        let request: [String: Any] = [
            "id": 1,
            "method": "initialize",
            "params": ["clientInfo": ["name": "aiusage", "title": "AIUsage", "version": version]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The ID of a JSON-RPC response line, or nil for notifications, server requests and anything else.
    static func responseID(in line: String) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["method"] == nil
        else {
            return nil
        }
        return object["id"] as? Int
    }

    private static func send(_ line: String, to handle: FileHandle) throws {
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    /// A task that yields the exit status. Call before `run()` so the exit can't be missed.
    private static func exitStatus(of process: Process) -> Task<Int32, Never> {
        let (stream, continuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            continuation.yield(process.terminationStatus)
            continuation.finish()
        }
        return Task {
            for await status in stream {
                return status
            }
            return -1
        }
    }

    /// Terminates the process after a timeout unless the returned task is cancelled first.
    private static func terminate(_ process: Process, after timeout: Duration) -> Task<Void, Never> {
        Task {
            guard (try? await Task.sleep(for: timeout)) != nil else {
                return
            }
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
