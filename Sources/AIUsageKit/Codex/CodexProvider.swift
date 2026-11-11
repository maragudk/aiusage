import Foundation

/// OpenAI Codex subscription usage, read with the ChatGPT login that the Codex CLI keeps in `auth.json`.
///
/// `auth.json` is re-read on every fetch and never written. Codex refresh tokens are single-use, so refreshing
/// here would break Codex's own login. When the token has expired, `loginRepair` lets Codex fix it.
public struct CodexProvider: UsageProvider {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let expiredMessage = "Codex login expired."

    public let id = "codex"
    public let name = "Codex"

    private let http: any HTTPClient
    private let authFile: URL
    private let userAgent: String
    private let version: String
    private let locateCodex: @Sendable () -> URL?
    private let now: @Sendable () -> Date

    /// - Parameter version: the app version, sent in the User-Agent.
    public init(http: any HTTPClient = URLSessionHTTPClient.shared, version: String) {
        self.init(
            http: http,
            authFile: CodexHome.authFile(),
            userAgent: "aiusage/\(version)",
            version: version,
            locateCodex: { CodexHome.locateCLI() },
            now: { Date() }
        )
    }

    init(
        http: any HTTPClient,
        authFile: URL,
        userAgent: String,
        version: String = "test",
        locateCodex: @escaping @Sendable () -> URL?,
        now: @escaping @Sendable () -> Date
    ) {
        self.http = http
        self.authFile = authFile
        self.userAgent = userAgent
        self.version = version
        self.locateCodex = locateCodex
        self.now = now
    }

    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: authFile.path) && locateCodex() != nil
    }

    public var loginRepair: LoginRepair? {
        guard let codex = locateCodex() else {
            return nil
        }
        let repair = CodexLoginRepair(codex: codex, version: version, isLoginValid: { [self] in await isLoginAccepted() })
        return LoginRepair(
            title: "Refresh Codex login",
            help: "Lets Codex refresh its own login. If that isn't enough, Codex opens its sign-in page in your browser.",
            perform: repair.run
        )
    }

    public func fetchLimits() async throws(UsageError) -> [UsageLimit] {
        let auth = try readAuth()
        if isExpired(auth) {
            throw .loginExpired(Self.expiredMessage)
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = auth.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await http.get(request, provider: id, expiredMessage: Self.expiredMessage)
        return try CodexUsageParser.parse(data, now: now())
    }

    private func readAuth() throws(UsageError) -> CodexAuth {
        guard let data = try? Data(contentsOf: authFile) else {
            throw .notLoggedIn(CodexAuth.notLoggedInMessage)
        }
        return try CodexAuth.parse(data)
    }

    /// Whether the token's JWT `exp` has passed. A token that isn't a readable JWT is left to the server to judge.
    private func isExpired(_ auth: CodexAuth) -> Bool {
        guard let expiry = CodexAuth.expiry(ofJWT: auth.accessToken) else {
            return false
        }
        return now() >= expiry
    }

    /// Whether the server accepts the stored login, judged by an actual usage request.
    ///
    /// Only login failures count as rejection. A network or server error says nothing about the login,
    /// so it shouldn't send the user to the browser.
    func isLoginAccepted() async -> Bool {
        do {
            _ = try await fetchLimits()
            return true
        } catch {
            switch error {
            case .loginExpired, .notLoggedIn:
                return false
            case .unsupported, .keychainDenied, .keychain, .rateLimited, .server, .http, .network, .invalidResponse:
                return true
            }
        }
    }
}
