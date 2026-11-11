import Foundation
import Testing

@testable import AIUsageKit

struct ClaudeProviderTests {
    private let now = Date(timeIntervalSince1970: 1_762_862_400)

    private func credentials(token: String = "test-access-token", expiresAt: Date?) -> Data {
        let expiry = expiresAt.map { #", "expiresAt": \#(Int64($0.timeIntervalSince1970 * 1_000))"# } ?? ""
        return Data(#"{"claudeAiOauth": {"accessToken": "\#(token)", "refreshToken": "test-refresh-token"\#(expiry)}}"#.utf8)
    }

    private func provider(http: FakeHTTPClient, credentials: Data) -> ClaudeProvider {
        ClaudeProvider(http: http, readCredentials: { credentials }, now: { [now] in now })
    }

    @Test
    func `sends the token and beta header to the usage endpoint`() async throws {
        let http = FakeHTTPClient(body: try Fixture.data("claude-usage"))
        let limits = try await provider(http: http, credentials: credentials(expiresAt: now.addingTimeInterval(3_600))).fetchLimits()

        #expect(limits.map(\.name) == ["Weekly", "Fable"])
        let request = try #require(http.sentRequests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test
    func `an expired token is reported without calling the API`() async {
        let http = FakeHTTPClient()
        await #expect(throws: UsageError.loginExpired(ClaudeProvider.expiredMessage)) {
            try await provider(http: http, credentials: credentials(expiresAt: now.addingTimeInterval(-1))).fetchLimits()
        }
        #expect(http.sentRequests.isEmpty)
    }

    @Test
    func `a token without an expiry is used`() async throws {
        let http = FakeHTTPClient(body: try Fixture.data("claude-usage"))
        _ = try await provider(http: http, credentials: credentials(expiresAt: nil)).fetchLimits()
        #expect(http.sentRequests.count == 1)
    }

    @Test
    func `401 means the token expired`() async {
        let http = FakeHTTPClient(status: 401, body: Data(#"{"error": "nope"}"#.utf8))
        await #expect(throws: UsageError.loginExpired(ClaudeProvider.expiredMessage)) {
            try await provider(http: http, credentials: credentials(expiresAt: now.addingTimeInterval(3_600))).fetchLimits()
        }
    }

    @Test
    func `429 is rate limited with retry after`() async {
        let http = FakeHTTPClient(status: 429, headers: ["Retry-After": "120"])
        await #expect(throws: UsageError.rateLimited(retryAfter: 120)) {
            try await provider(http: http, credentials: credentials(expiresAt: nil)).fetchLimits()
        }
    }

    @Test
    func `5xx is a server error`() async {
        let http = FakeHTTPClient(status: 503)
        await #expect(throws: UsageError.server(status: 503)) {
            try await provider(http: http, credentials: credentials(expiresAt: nil)).fetchLimits()
        }
    }

    @Test(arguments: [
        #"not json"#,
        #"{"claudeAiOauth": {}}"#,
        #"{"claudeAiOauth": {"accessToken": ""}}"#,
        #"{}"#,
    ])
    func `credentials without a token mean not logged in`(json: String) {
        #expect(throws: UsageError.notLoggedIn(ClaudeCredentials.notLoggedInMessage)) {
            try ClaudeCredentials.accessToken(from: Data(json.utf8), now: now)
        }
    }
}
