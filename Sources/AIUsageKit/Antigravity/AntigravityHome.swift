import Foundation

/// Where the Antigravity CLI (`agy`) keeps its login and where it is installed.
enum AntigravityHome {
    /// The file `agy` stores its login in instead of the Keychain, which it does when `SSH_TTY` is set.
    static func tokenFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".gemini/antigravity-cli/antigravity-oauth-token")
    }

    /// Places to look for the CLI. A GUI app doesn't get the shell's `PATH`, so these are fixed.
    static func cliCandidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            home.appending(path: ".local/bin/agy"),
            URL(filePath: "/opt/homebrew/bin/agy"),
            URL(filePath: "/usr/local/bin/agy"),
        ]
    }

    /// The first candidate that is an executable file.
    static func locateCLI(candidates: [URL] = cliCandidates()) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
