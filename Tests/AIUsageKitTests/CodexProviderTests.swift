import Foundation
import Testing

@testable import AIUsageKit

struct CodexProviderTests {
    private let now = Date(timeIntervalSince1970: 1_762_873_200)

    /// A JWT with only the claims the provider reads. The signature is not checked.
    private func jwt(expiresAt: Date?) -> String {
        let claims = expiresAt.map { #"{"exp": \#(Int($0.timeIntervalSince1970))}"# } ?? "{}"
        return [#"{"alg":"none"}"#, claims].map(base64URL).joined(separator: ".") + ".signature"
    }

    private func base64URL(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacing("+", with: "-")
            .replacing("/", with: "_")
            .replacing("=", with: "")
    }

    private func authFile(token: String, accountID: String? = "test-account") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = accountID.map { #", "account_id": "\#($0)""# } ?? ""
        let json = #"{"auth_mode": "chatgpt", "OPENAI_API_KEY": null, "tokens": {"id_token": "x", "access_token": "\#(token)", "refresh_token": "r"\#(account)}, "last_refresh": "2026-10-29T08:00:00Z"}"#
        let url = directory.appending(path: "auth.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    private func provider(http: FakeHTTPClient, authFile: URL, codex: URL? = URL(filePath: "/bin/echo")) -> CodexProvider {
        CodexProvider(http: http, authFile: authFile, userAgent: "aiusage/1.2.3", locateCodex: { codex }, now: { [now] in now })
    }

    @Test
    func `sends the token and account ID to the usage endpoint`() async throws {
        let token = jwt(expiresAt: now.addingTimeInterval(3_600))
        let http = FakeHTTPClient(body: try Fixture.data("codex-usage"))
        let limits = try await provider(http: http, authFile: authFile(token: token)).fetchLimits()

        #expect(limits.map(\.name) == ["5-hour", "Weekly", "Code review · Weekly", "codex_other · 30-minute"])
        let request = try #require(http.sentRequests.first)
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "test-account")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "aiusage/1.2.3")
    }

    @Test
    func `the account header is left out when there is no account ID`() async throws {
        let http = FakeHTTPClient(body: try Fixture.data("codex-usage"))
        _ = try await provider(http: http, authFile: authFile(token: jwt(expiresAt: nil), accountID: nil)).fetchLimits()
        #expect(http.sentRequests.first?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
    }

    @Test
    func `an expired JWT is reported without calling the API`() async throws {
        let http = FakeHTTPClient()
        let file = try authFile(token: jwt(expiresAt: now.addingTimeInterval(-60)))
        await #expect(throws: UsageError.loginExpired(CodexProvider.expiredMessage)) {
            try await provider(http: http, authFile: file).fetchLimits()
        }
        #expect(http.sentRequests.isEmpty)
    }

    @Test
    func `an opaque token is sent and a 401 means expired`() async throws {
        let http = FakeHTTPClient(status: 401, body: Data(#"{"error": {"code": "token_expired"}}"#.utf8))
        let file = try authFile(token: "not-a-jwt")
        await #expect(throws: UsageError.loginExpired(CodexProvider.expiredMessage)) {
            try await provider(http: http, authFile: file).fetchLimits()
        }
        #expect(http.sentRequests.count == 1)
    }

    @Test
    func `is available only with both auth file and CLI`() throws {
        let http = FakeHTTPClient()
        let file = try authFile(token: "t")
        let missing = file.deletingLastPathComponent().appending(path: "missing.json")

        #expect(provider(http: http, authFile: file).isAvailable)
        #expect(!provider(http: http, authFile: missing).isAvailable)
        #expect(!provider(http: http, authFile: file, codex: nil).isAvailable)
        #expect(provider(http: http, authFile: file).loginRepair != nil)
        #expect(provider(http: http, authFile: file, codex: nil).loginRepair == nil)
    }

    @Test(arguments: [
        (#"{"auth_mode": "apikey", "OPENAI_API_KEY": "sk-test"}"#, UsageError.unsupported(CodexAuth.apiKeyMessage)),
        (#"{"tokens": {"access_token": ""}}"#, .notLoggedIn(CodexAuth.notLoggedInMessage)),
        (#"{"tokens": null}"#, .notLoggedIn(CodexAuth.notLoggedInMessage)),
        ("garbage", .notLoggedIn(CodexAuth.notLoggedInMessage)),
    ])
    func `auth files without a ChatGPT token are reported`(json: String, expected: UsageError) {
        #expect(throws: expected) {
            try CodexAuth.parse(Data(json.utf8))
        }
    }

    @Test
    func `reads the JWT expiry`() {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CodexAuth.expiry(ofJWT: jwt(expiresAt: expiry)) == expiry)
        #expect(CodexAuth.expiry(ofJWT: jwt(expiresAt: nil)) == nil)
        #expect(CodexAuth.expiry(ofJWT: "a.b") == nil)
        #expect(CodexAuth.expiry(ofJWT: "") == nil)
    }

    @Test
    func `auth file honours CODEX_HOME`() {
        let home = URL(filePath: "/Users/someone")
        #expect(CodexHome.authFile(environment: [:], home: home).path == "/Users/someone/.codex/auth.json")
        #expect(CodexHome.authFile(environment: ["CODEX_HOME": "/tmp/codex"], home: home).path == "/tmp/codex/auth.json")
        #expect(CodexHome.authFile(environment: ["CODEX_HOME": ""], home: home).path == "/Users/someone/.codex/auth.json")
    }

    @Test
    func `finds the CLI in the first candidate that is executable`() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notExecutable = directory.appending(path: "a")
        let executable = directory.appending(path: "b")
        try Data().write(to: notExecutable)
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let candidates = [directory.appending(path: "missing"), notExecutable, executable]
        #expect(CodexHome.locateCLI(candidates: candidates) == executable)
        #expect(CodexHome.locateCLI(candidates: [notExecutable]) == nil)
    }

    @Test
    func `CLI candidates are in the documented order`() {
        let home = URL(filePath: "/Users/someone")
        #expect(CodexHome.cliCandidates(home: home).map(\.path) == [
            "/Users/someone/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ])
    }
}
