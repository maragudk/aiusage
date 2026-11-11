import Foundation

/// Claude subscription usage, read with the OAuth token that Claude Code keeps in the login Keychain.
///
/// The Keychain is re-read on every fetch, because Claude Code rotates the token. The token is never
/// refreshed or written here: refreshing it outside Claude Code could log Claude Code out.
public struct ClaudeProvider: UsageProvider {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let expiredMessage = "Token expired, open Claude Code to refresh."

    public let id = "claude"
    public let name = "Claude"

    private let http: any HTTPClient
    private let readCredentials: @Sendable () throws(UsageError) -> Data
    private let now: @Sendable () -> Date

    public init(http: any HTTPClient = URLSessionHTTPClient.shared) {
        self.init(http: http, readCredentials: { () throws(UsageError) in try ClaudeCredentials.readFromKeychain() }, now: { Date() })
    }

    init(
        http: any HTTPClient,
        readCredentials: @escaping @Sendable () throws(UsageError) -> Data,
        now: @escaping @Sendable () -> Date
    ) {
        self.http = http
        self.readCredentials = readCredentials
        self.now = now
    }

    public var isAvailable: Bool { true }

    public var loginRepair: LoginRepair? { nil }

    public func fetchLimits() async throws(UsageError) -> [UsageLimit] {
        let token = try ClaudeCredentials.accessToken(from: await readCredentialsOffPool(), now: now())
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await http.get(request, provider: id, expiredMessage: Self.expiredMessage)
        return try ClaudeUsageParser.parse(data)
    }

    private static let keychainQueue = DispatchQueue(label: "dk.maragu.aiusage.keychain")

    /// Reads the credentials on a dedicated queue. The Keychain read blocks while macOS shows its access
    /// prompt, which must not tie up a thread of Swift's cooperative pool.
    private func readCredentialsOffPool() async throws(UsageError) -> Data {
        let read = readCredentials
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Data, UsageError>, Never>) in
            Self.keychainQueue.async {
                do throws(UsageError) {
                    continuation.resume(returning: .success(try read()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        return try result.get()
    }
}
