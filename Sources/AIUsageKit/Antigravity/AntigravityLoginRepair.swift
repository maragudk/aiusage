import Foundation

/// Lets the Antigravity CLI renew its own expired login. Only ever run on a user click.
///
/// It runs `agy models`, which lists the available models. To do that, `agy` renews its access token with its
/// own refresh token and saves the new token in the Keychain itself. Listing models doesn't start a model turn,
/// so it doesn't spend quota.
///
/// `agy` can open a browser sign-in when it can't renew the token. The command runs with failing `open` and
/// `xdg-open` shims first on `PATH` and as `BROWSER`, so it can't, and with auto-update off and a timeout.
/// If the refresh token no longer works, the panel asks the user to run `agy` and log in.
///
/// The app never calls the Google token endpoint and never writes the Keychain item.
/// Process output is discarded and never logged, because it can contain account details.
struct AntigravityLoginRepair: Sendable {
    /// Runs a command with an environment and working directory, like `Command.run`.
    typealias Runner = @Sendable (
        _ executable: URL,
        _ arguments: [String],
        _ timeout: Duration,
        _ environment: [String: String]?,
        _ currentDirectory: URL?
    ) async -> CommandResult

    let agy: URL
    /// Checks the login after the refresh, and returns whether the server accepts it.
    let checkLogin: @Sendable () async -> Bool
    var timeout: Duration = .seconds(60)
    var runCommand: Runner = Command.run

    private static let shimNames = ["open", "xdg-open"]

    func run(progress: @escaping @Sendable (String) -> Void) async {
        progress("Asking Antigravity to refresh its login…")
        let result = await refresh()
        let isValid = await checkLogin()
        Log.login.notice("agy models result=\(Self.describe(result), privacy: .public) valid=\(isValid, privacy: .public)")
    }

    /// Runs `agy models` in a private directory that holds the browser shims, then removes the directory.
    private func refresh() async -> CommandResult {
        let directory = FileManager.default.temporaryDirectory.appending(path: "aiusage-agy-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for name in Self.shimNames {
                let shim = directory.appending(path: name)
                try Data("#!/bin/sh\nexit 1\n".utf8).write(to: shim)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
            }
        } catch {
            // Without the shims, agy could open a browser, so it doesn't run.
            Log.login.error("could not create the browser shims for agy")
            return .launchFailed
        }
        return await runCommand(agy, ["models"], timeout, environment(shims: directory), directory)
    }

    /// The app's environment with the shims and the CLI's directory first on `PATH`, since a GUI app doesn't get
    /// the shell's `PATH`, and without `SSH_TTY`, which would make `agy` use its token file instead of the Keychain.
    private func environment(shims: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let paths = [shims.path, agy.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = (paths + [environment["PATH"]].compactMap(\.self)).joined(separator: ":")
        environment["BROWSER"] = shims.appending(path: "open").path
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        environment["SSH_TTY"] = nil
        return environment
    }

    private static func describe(_ result: CommandResult) -> String {
        switch result {
        case .exited(let status, _): "exited-\(status)"
        case .timedOut: "timedOut"
        case .launchFailed: "launchFailed"
        }
    }
}
