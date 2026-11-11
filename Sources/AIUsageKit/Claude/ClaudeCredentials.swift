import Foundation
import Security

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

    /// The credentials JSON from the login Keychain. May show the system's Keychain access prompt.
    static func readFromKeychain() throws(UsageError) -> Data {
        do {
            return try genericPassword(service: keychainService, account: NSUserName())
        } catch .notLoggedIn {
            // Fall back to any account, in case Claude Code stored the item under another account name.
            return try genericPassword(service: keychainService, account: nil)
        }
    }

    private static func genericPassword(service: String, account: String?) throws(UsageError) -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw .notLoggedIn(notLoggedInMessage)
            }
            return data
        case errSecItemNotFound:
            throw .notLoggedIn(notLoggedInMessage)
        case errSecUserCanceled, errSecAuthFailed:
            throw .keychainDenied
        default:
            throw .keychain(status: status)
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
