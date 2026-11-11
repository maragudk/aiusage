import Foundation

/// The ChatGPT login that the Codex CLI stores in `auth.json`. Read-only: never refreshed or written here.
struct CodexAuth: Sendable {
    static let notLoggedInMessage = "No Codex login found. Run codex login first."
    static let apiKeyMessage = "Codex uses an API key, which has no subscription limits to show."

    let accessToken: String
    let accountID: String?

    static func parse(_ data: Data) throws(UsageError) -> CodexAuth {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            throw .notLoggedIn(notLoggedInMessage)
        }
        guard let token = stored.tokens?.accessToken, !token.isEmpty else {
            if let apiKey = stored.apiKey, !apiKey.isEmpty {
                throw .unsupported(apiKeyMessage)
            }
            throw .notLoggedIn(notLoggedInMessage)
        }
        let accountID = stored.tokens?.accountID.flatMap { $0.isEmpty ? nil : $0 }
        return CodexAuth(accessToken: token, accountID: accountID)
    }

    /// The `exp` claim of a JWT, or nil if the token isn't a readable JWT. The signature isn't checked;
    /// this only avoids a request that would fail anyway.
    static func expiry(ofJWT token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return nil
        }
        var payload = String(parts[1]).replacing("-", with: "+").replacing("_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONDecoder().decode(Claims.self, from: data),
              let exp = claims.exp
        else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    private struct Stored: Decodable {
        let apiKey: String?
        let tokens: Tokens?

        enum CodingKeys: String, CodingKey {
            case apiKey = "OPENAI_API_KEY"
            case tokens
        }

        struct Tokens: Decodable {
            let accessToken: String?
            let accountID: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountID = "account_id"
            }
        }
    }

    private struct Claims: Decodable {
        let exp: Double?
    }
}
