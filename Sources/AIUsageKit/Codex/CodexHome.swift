import Foundation

/// Where the Codex CLI keeps its login and where it is installed.
enum CodexHome {
    /// `$CODEX_HOME/auth.json`, or `~/.codex/auth.json` when `CODEX_HOME` isn't set.
    static func authFile(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(filePath: (codexHome as NSString).expandingTildeInPath, directoryHint: .isDirectory)
                .appending(path: "auth.json")
        }
        return home.appending(path: ".codex/auth.json")
    }

    /// Places to look for the CLI. A GUI app doesn't get the shell's `PATH`, so these are fixed.
    static func cliCandidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            home.appending(path: ".local/bin/codex"),
            URL(filePath: "/opt/homebrew/bin/codex"),
            URL(filePath: "/usr/local/bin/codex"),
        ]
    }

    /// The first candidate that is an executable file.
    static func locateCLI(candidates: [URL] = cliCandidates()) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
