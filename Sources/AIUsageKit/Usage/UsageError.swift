import Foundation

/// Why a provider couldn't fetch its usage.
public enum UsageError: Error, Equatable, Sendable {
    /// The owning tool has no stored login.
    case notLoggedIn(String)
    /// The stored token's expiry has passed, or the API rejected it with HTTP 401. Only the owning tool can fix this.
    case loginExpired(String)
    /// The user denied Keychain access.
    case keychainDenied
    /// Reading the Keychain failed some other way. `status` is the exit status of the `security` tool,
    /// which is the low byte of the `OSStatus`.
    case keychainReadFailed(status: Int32)
    /// Reading the Keychain didn't finish in time, for example because an access prompt went unanswered.
    case keychainTimedOut
    /// The `security` tool that reads the Keychain couldn't be started.
    case keychainToolFailed
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
            "Keychain access was denied. Trying again later."
        case .keychainReadFailed(let status):
            "Couldn't read the Keychain (security exited with status \(status))."
        case .keychainTimedOut:
            "Reading the Keychain took too long. Trying again later."
        case .keychainToolFailed:
            "Couldn't run /usr/bin/security to read the Keychain."
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
        case .keychainReadFailed: "keychainReadFailed"
        case .keychainTimedOut: "keychainTimedOut"
        case .keychainToolFailed: "keychainToolFailed"
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
        case .rateLimited, .server, .keychainTimedOut, .keychainDenied: true
        case .notLoggedIn, .loginExpired, .keychainReadFailed, .keychainToolFailed, .http, .network,
             .invalidResponse, .unsupported: false
        }
    }

    /// Whether the last good data is still worth showing next to the error.
    public var keepsLastData: Bool {
        switch self {
        case .rateLimited, .server, .network, .http, .invalidResponse, .keychainReadFailed, .keychainTimedOut,
             .keychainToolFailed: true
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
