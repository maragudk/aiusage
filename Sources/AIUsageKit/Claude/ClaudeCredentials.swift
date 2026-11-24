import Foundation

/// Reads the OAuth access token that Claude Code stores. Read-only: never refreshes or writes the token.
enum ClaudeCredentials {
    static let keychainService = "Claude Code-credentials"
    static let notLoggedInMessage = "No Claude Code login found. Log in with Claude Code first."

    /// The access token from the stored credentials JSON, `{"claudeAiOauth": {"accessToken", "expiresAt"}}`.
    static func accessToken(from data: Data, now: Date) throws(UsageError) -> String {
        guard let credentials = try? JSONDecoder().decode(Stored.self, from: data),
              let token = credentials.claudeAiOauth?.accessToken, !token.isEmpty
        else {
            throw .notLoggedIn(notLoggedInMessage)
        }
        if let expiresAt = credentials.claudeAiOauth?.expiresAt, expiresAt > 0,
           now >= Date(timeIntervalSince1970: expiresAt / 1_000) {
            throw .loginExpired(ClaudeProvider.expiredMessage)
        }
        return token
    }

    /// The credentials JSON from the login Keychain. See `KeychainPassword` for why this reads through the
    /// `security` tool. Read only: this never writes the item or changes its access list.
    static func readFromKeychain(
        account: String = NSUserName(),
        run: Command.Runner = Command.run
    ) async throws(UsageError) -> Data {
        do {
            return try await KeychainPassword.read(service: keychainService, account: account, notFoundMessage: notLoggedInMessage, run: run)
        } catch .notLoggedIn {
            // Fall back to any account, in case Claude Code stored the item under another account name.
            return try await KeychainPassword.read(service: keychainService, account: nil, notFoundMessage: notLoggedInMessage, run: run)
        }
    }

    private struct Stored: Decodable {
        let claudeAiOauth: OAuth?

        struct OAuth: Decodable {
            let accessToken: String?
            /// Unix milliseconds.
            let expiresAt: Double?
        }
    }
}
