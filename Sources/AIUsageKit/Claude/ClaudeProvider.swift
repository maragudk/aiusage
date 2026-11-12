import Foundation

/// Claude subscription usage, read with the OAuth token that Claude Code keeps in the login Keychain.
///
/// The Keychain is re-read on every fetch, because Claude Code rotates the token, and nothing is cached.
/// The token is never refreshed or written here: refreshing it outside Claude Code could log Claude Code out.
public struct ClaudeProvider: UsageProvider {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let expiredMessage = "Token expired, open Claude Code to refresh."

    public let id = "claude"
    public let name = "Claude"

    private let http: any HTTPClient
    private let readCredentials: @Sendable () async throws(UsageError) -> Data
    private let now: @Sendable () -> Date

    public init(http: any HTTPClient = URLSessionHTTPClient.shared) {
        // At most one Keychain read in flight, so overlapping fetches can't stack two Keychain prompts.
        let reads = SingleFlight<Result<Data, UsageError>>()
        self.init(
            http: http,
            readCredentials: { () async throws(UsageError) in
                try await reads.run {
                    do throws(UsageError) {
                        return .success(try await ClaudeCredentials.readFromKeychain())
                    } catch {
                        return .failure(error)
                    }
                }.get()
            },
            now: { Date() }
        )
    }

    init(
        http: any HTTPClient,
        readCredentials: @escaping @Sendable () async throws(UsageError) -> Data,
        now: @escaping @Sendable () -> Date
    ) {
        self.http = http
        self.readCredentials = readCredentials
        self.now = now
    }

    public var isAvailable: Bool { true }

    public var loginRepair: LoginRepair? { nil }

    public func fetchLimits() async throws(UsageError) -> [UsageLimit] {
        let token = try ClaudeCredentials.accessToken(from: await readCredentials(), now: now())
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await http.get(request, provider: id, expiredMessage: Self.expiredMessage)
        return try ClaudeUsageParser.parse(data)
    }
}
