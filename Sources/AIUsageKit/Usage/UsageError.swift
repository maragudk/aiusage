import Foundation

/// Why a provider couldn't fetch its usage.
public enum UsageError: Error, Equatable, Sendable {
    /// The owning tool has no stored login.
    case notLoggedIn(String)
    /// The stored token is expired or was rejected. Only the owning tool can fix this.
    case loginExpired(String)
    /// The user denied Keychain access.
    case keychainDenied
    /// Some other Keychain error, by `OSStatus`.
    case keychain(status: Int32)
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case http(status: Int)
    case network
    case invalidResponse
    /// The stored login is of a kind that has no usage limits to show.
    case unsupported(String)

    /// A short message for the panel.
    public var message: String {
        switch self {
        case .notLoggedIn(let message), .loginExpired(let message), .unsupported(let message):
            message
        case .keychainDenied:
            "Keychain access was denied. Click Refresh to ask again."
        case .keychain(let status):
            "Couldn't read the Keychain (error \(status))."
        case .rateLimited:
            "Rate limited. Trying again later."
        case .server(let status):
            "The server had a problem (HTTP \(status)). Trying again later."
        case .http(let status):
            "Unexpected response (HTTP \(status))."
        case .network:
            "Couldn't connect. Check your network."
        case .invalidResponse:
            "Couldn't read the usage response."
        }
    }

    /// A stable name for logs. Never contains identifiers.
    public var category: String {
        switch self {
        case .notLoggedIn: "notLoggedIn"
        case .loginExpired: "loginExpired"
        case .keychainDenied: "keychainDenied"
        case .keychain: "keychain"
        case .rateLimited: "rateLimited"
        case .server: "server"
        case .http: "http"
        case .network: "network"
        case .invalidResponse: "invalidResponse"
        case .unsupported: "unsupported"
        }
    }

    /// Whether automatic refreshes should back off after this error.
    public var shouldBackOff: Bool {
        switch self {
        case .rateLimited, .server: true
        case .notLoggedIn, .loginExpired, .keychainDenied, .keychain, .http, .network, .invalidResponse, .unsupported: false
        }
    }

    /// Whether the last good data is still worth showing next to the error.
    public var keepsLastData: Bool {
        switch self {
        case .rateLimited, .server, .network, .http, .invalidResponse, .keychain: true
        case .notLoggedIn, .loginExpired, .keychainDenied, .unsupported: false
        }
    }

    public var retryAfter: TimeInterval? {
        if case .rateLimited(let retryAfter) = self {
            retryAfter
        } else {
            nil
        }
    }
}
