import Foundation

/// The OAuth login that the Antigravity CLI (`agy`) stores. Read-only: never refreshed or written here.
///
/// `agy` keeps it in the login Keychain as a generic password with service `gemini` and account `antigravity`.
/// The value is `go-keyring-base64:` and then base64 of JSON in the shape of Go's `oauth2.Token`:
/// `{"auth_method": …, "token": {"access_token", "token_type", "refresh_token", "expiry"}}`, where `expiry` is
/// RFC 3339. When `SSH_TTY` is set, `agy` keeps the same JSON in a file instead.
struct AntigravityCredentials: Sendable, Equatable {
    static let keychainService = "gemini"
    static let keychainAccount = "antigravity"
    static let notLoggedInMessage = "No Antigravity login found. Run agy and log in first."
    private static let keyringPrefix = "go-keyring-base64:"
    /// The hex encoding that older versions of the Go keyring library wrote.
    private static let legacyKeyringPrefix = "go-keyring-encoded:"

    let accessToken: String
    /// When the access token expires, or nil if the stored login doesn't say.
    let expiresAt: Date?

    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else {
            return false
        }
        return now >= expiresAt
    }

    /// The credentials from the Keychain value or token file, with or without the `go-keyring-base64:` prefix.
    static func parse(_ data: Data) throws(UsageError) -> AntigravityCredentials {
        var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(keyringPrefix) {
            guard let decoded = Data(base64Encoded: String(text.dropFirst(keyringPrefix.count))) else {
                throw .notLoggedIn(notLoggedInMessage)
            }
            text = String(decoding: decoded, as: UTF8.self)
        } else if text.hasPrefix(legacyKeyringPrefix) {
            guard let decoded = KeychainPassword.hexDecoded(Data(text.dropFirst(legacyKeyringPrefix.count).utf8)) else {
                throw .notLoggedIn(notLoggedInMessage)
            }
            text = String(decoding: decoded, as: UTF8.self)
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: Data(text.utf8)),
              let token = stored.token ?? stored.bare,
              let accessToken = token.accessToken, !accessToken.isEmpty
        else {
            throw .notLoggedIn(notLoggedInMessage)
        }
        // Go writes the zero time, year 1, for a token without an expiry.
        let expiresAt = token.expiry.flatMap(ISO8601.date(from:)).flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
        return AntigravityCredentials(accessToken: accessToken, expiresAt: expiresAt)
    }

    /// The stored login: the Keychain item, or the token file when there is no Keychain item.
    ///
    /// The Keychain is read through the `security` tool, like Claude's. See `KeychainPassword`.
    static func read(
        tokenFile: URL = AntigravityHome.tokenFile(),
        run: Command.Runner = Command.run
    ) async throws(UsageError) -> Data {
        do {
            return try await KeychainPassword.read(
                service: keychainService,
                account: keychainAccount,
                notFoundMessage: notLoggedInMessage,
                run: run
            )
        } catch .notLoggedIn {
            guard let data = try? Data(contentsOf: tokenFile) else {
                throw .notLoggedIn(notLoggedInMessage)
            }
            return data
        }
    }

    private struct Stored: Decodable {
        let token: Token?
        /// The token fields at the top level, for a file that holds only the token.
        let bare: Token?

        enum CodingKeys: String, CodingKey {
            case token
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            token = container.lenient(Token.self, forKey: .token)
            bare = try? Token(from: decoder)
        }
    }

    private struct Token: Decodable {
        let accessToken: String?
        let expiry: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiry
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = container.lenient(String.self, forKey: .accessToken)
            expiry = container.lenient(String.self, forKey: .expiry)
        }
    }
}
