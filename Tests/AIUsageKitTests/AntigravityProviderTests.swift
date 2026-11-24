import Foundation
import Synchronization
import Testing

@testable import AIUsageKit

struct AntigravityProviderTests {
    private let now = Date(timeIntervalSince1970: 1_795_600_000)

    private func credentials(expiresAt: Date?) -> Data {
        let expiry = expiresAt.map { #", "expiry": "\#($0.formatted(.iso8601))""# } ?? ""
        let json = #"{"token": {"access_token": "test-access-token", "token_type": "Bearer", "refresh_token": "r"\#(expiry)}, "auth_method": "consumer"}"#
        return Data(("go-keyring-base64:" + Data(json.utf8).base64EncodedString()).utf8)
    }

    private func provider(
        http: some HTTPClient,
        credentials: Data?,
        agy: URL? = URL(filePath: "/bin/echo"),
        tokenFile: URL = URL(filePath: "/nonexistent/antigravity-oauth-token"),
        run: @escaping AntigravityLoginRepair.Runner = { _, _, _, _, _ in .exited(status: 0, output: Data()) }
    ) -> AntigravityProvider {
        AntigravityProvider(
            http: http,
            readCredentials: { () throws(UsageError) in
                guard let credentials else {
                    throw .notLoggedIn(AntigravityCredentials.notLoggedInMessage)
                }
                return credentials
            },
            tokenFile: tokenFile,
            locateAgy: { agy },
            now: { [now] in now },
            run: run
        )
    }

    @Test
    func `posts to the daily quota summary with the token and the hub client identity`() async throws {
        let http = FakeHTTPClient(body: try Fixture.data("antigravity-quota"))
        let limits = try await provider(http: http, credentials: credentials(expiresAt: now.addingTimeInterval(600))).fetchLimits()

        #expect(limits.map(\.name) == ["Gemini · 5-hour", "Gemini · Weekly", "Claude and GPT · 5-hour", "Claude and GPT · Weekly"])
        let request = try #require(http.sentRequests.first)
        #expect(http.sentRequests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")
        #expect(request.httpBody == Data("{}".utf8))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("antigravity/hub/") == true)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("os_type=darwin") == true)
    }

    @Test
    func `an expired token is reported without calling the API`() async {
        let http = FakeHTTPClient()
        await #expect(throws: UsageError.loginExpired(AntigravityProvider.expiredMessage)) {
            try await provider(http: http, credentials: credentials(expiresAt: now)).fetchLimits()
        }
        #expect(http.sentRequests.isEmpty)
    }

    @Test
    func `a 401 means expired`() async {
        let http = FakeHTTPClient(status: 401, body: Data(#"{"error": {"code": 401, "status": "UNAUTHENTICATED"}}"#.utf8))
        await #expect(throws: UsageError.loginExpired(AntigravityProvider.expiredMessage)) {
            try await provider(http: http, credentials: credentials(expiresAt: nil)).fetchLimits()
        }
    }

    @Test
    func `a 403 that requires a subscription says there is no subscription`() async throws {
        let http = FakeHTTPClient(status: 403, body: try Fixture.data("antigravity-subscription-required"))
        await #expect(throws: UsageError.unsupported(AntigravityProvider.noSubscriptionMessage)) {
            try await provider(http: http, credentials: credentials(expiresAt: nil)).fetchLimits()
        }
    }

    @Test(arguments: [
        (403, #"{"error": {"code": 403, "status": "PERMISSION_DENIED", "details": [{"reason": "OTHER"}]}}"#, UsageError.http(status: 403)),
        (403, "not json", .http(status: 403)),
        (429, "{}", .rateLimited(retryAfter: 120)),
        (503, "{}", .server(status: 503)),
    ])
    func `other failures use the shared mapping`(status: Int, body: String, expected: UsageError) async {
        let http = FakeHTTPClient(status: status, body: Data(body.utf8), headers: ["Retry-After": "120"])
        await #expect(throws: expected) {
            try await provider(http: http, credentials: credentials(expiresAt: nil)).fetchLimits()
        }
    }

    @Test
    func `is available with the CLI or the token file, and repairs only with the CLI`() throws {
        let http = FakeHTTPClient()
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("{}".utf8).write(to: file)

        #expect(provider(http: http, credentials: nil).isAvailable)
        #expect(provider(http: http, credentials: nil, agy: nil, tokenFile: file).isAvailable)
        #expect(!provider(http: http, credentials: nil, agy: nil).isAvailable)
        #expect(provider(http: http, credentials: nil).loginRepair?.title == "Refresh Antigravity login")
        #expect(provider(http: http, credentials: nil, agy: nil, tokenFile: file).loginRepair == nil)
    }

    @Test
    func `the repair runs agy models, bounded and without a browser or an update`() async throws {
        let runner = FakeRunner(results: [.exited(status: 0, output: Data())])
        let agy = URL(filePath: "/Users/someone/.local/bin/agy")
        let repair = try #require(provider(http: FakeHTTPClient(status: 401), credentials: credentials(expiresAt: nil), agy: agy, run: runner.run).loginRepair)
        await repair.perform { _ in }

        let call = try #require(runner.calls.first)
        #expect(runner.calls.count == 1)
        #expect(call.executable == agy)
        #expect(call.arguments == ["models"])
        #expect(call.timeout == .seconds(60))
        let environment = try #require(call.environment)
        #expect(environment["AGY_CLI_DISABLE_AUTO_UPDATE"] == "true")
        #expect(environment["SSH_TTY"] == nil)
        let directory = try #require(call.currentDirectory)
        #expect(environment["BROWSER"] == directory.appending(path: "open").path)
        #expect(environment["PATH"]?.hasPrefix("\(directory.path):/Users/someone/.local/bin:") == true)
        // The private directory with the browser shims is removed afterwards.
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test
    func `the browser shims fail, so agy can't start a sign-in`() async throws {
        let result = Mutex<CommandResult?>(nil)
        let repair = try #require(provider(http: FakeHTTPClient(), credentials: credentials(expiresAt: nil), run: { _, _, timeout, environment, directory in
            let outcome = await Command.run(
                URL(filePath: "/bin/sh"),
                arguments: ["-c", #"open https://example.com; a=$?; xdg-open https://example.com; b=$?; "$BROWSER" x; printf '%s %s %s' $a $b $?"#],
                timeout: timeout,
                environment: environment,
                currentDirectory: directory
            )
            result.withLock { $0 = outcome }
            return outcome
        }).loginRepair)
        await repair.perform { _ in }

        #expect(result.withLock { $0 } == .exited(status: 0, output: Data("1 1 1".utf8)))
    }

    @Test
    func `after a failed refresh the panel says to log in with agy`() async throws {
        let expired = credentials(expiresAt: now.addingTimeInterval(-60))
        let provider = provider(http: FakeHTTPClient(), credentials: expired)
        await #expect(throws: UsageError.loginExpired(AntigravityProvider.expiredMessage)) {
            try await provider.fetchLimits()
        }

        let repair = try #require(provider.loginRepair)
        await repair.perform { _ in }

        await #expect(throws: UsageError.loginExpired(AntigravityProvider.refreshFailedMessage)) {
            try await provider.fetchLimits()
        }
    }

    @Test(arguments: [CommandResult.timedOut, .launchFailed])
    func `an agy run that didn't finish says nothing about the login`(result: CommandResult) async throws {
        let provider = provider(http: FakeHTTPClient(), credentials: credentials(expiresAt: now.addingTimeInterval(-60)), run: { _, _, _, _, _ in result })
        let repair = try #require(provider.loginRepair)
        await repair.perform { _ in }

        await #expect(throws: UsageError.loginExpired(AntigravityProvider.expiredMessage)) {
            try await provider.fetchLimits()
        }
    }

    @Test
    func `a new login clears the failed refresh`() async throws {
        let stored = Mutex(credentials(expiresAt: now.addingTimeInterval(-60)))
        let provider = AntigravityProvider(
            http: FakeHTTPClient(body: try Fixture.data("antigravity-quota")),
            readCredentials: { stored.withLock { $0 } },
            tokenFile: URL(filePath: "/nonexistent"),
            locateAgy: { URL(filePath: "/bin/echo") },
            now: { [now] in now },
            run: { _, _, _, _, _ in .exited(status: 0, output: Data()) }
        )
        let repair = try #require(provider.loginRepair)
        await repair.perform { _ in }

        stored.withLock { $0 = credentials(expiresAt: now.addingTimeInterval(3_600)) }
        #expect(try await provider.fetchLimits().count == 4)
    }

    @Test
    func `a successful refresh leaves the usual expiry message for later expiries`() async throws {
        let stored = Mutex(credentials(expiresAt: now.addingTimeInterval(-60)))
        let provider = AntigravityProvider(
            http: FakeHTTPClient(body: try Fixture.data("antigravity-quota")),
            readCredentials: { stored.withLock { $0 } },
            tokenFile: URL(filePath: "/nonexistent"),
            locateAgy: { URL(filePath: "/bin/echo") },
            now: { [now] in now },
            run: { [now] _, _, _, _, _ in
                // agy refreshes its token and writes it to the Keychain.
                stored.withLock { $0 = credentials(expiresAt: now.addingTimeInterval(3_600)) }
                return .exited(status: 0, output: Data())
            }
        )
        let repair = try #require(provider.loginRepair)
        await repair.perform { _ in }

        #expect(try await provider.fetchLimits().count == 4)
    }
}
