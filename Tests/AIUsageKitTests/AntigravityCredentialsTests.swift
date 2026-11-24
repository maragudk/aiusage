import Foundation
import Testing

@testable import AIUsageKit

/// Decodes credentials from test strings. Nothing here touches the real Keychain or `~/.gemini`.
struct AntigravityCredentialsTests {
    private let now = Date(timeIntervalSince1970: 1_795_600_000)
    private let json = #"{"token": {"access_token": "test-access-token", "token_type": "Bearer", "refresh_token": "test-refresh", "expiry": "2026-11-24T11:57:21.411177+01:00", "expires_in": 3599}, "auth_method": "consumer"}"#

    private func keyringValue(_ json: String) -> Data {
        Data(("go-keyring-base64:" + Data(json.utf8).base64EncodedString() + "\n").utf8)
    }

    @Test
    func `decodes the go-keyring value that agy stores in the Keychain`() throws {
        let credentials = try AntigravityCredentials.parse(keyringValue(json))

        #expect(credentials.accessToken == "test-access-token")
        #expect(credentials.expiresAt == (try Fixture.date("2026-11-24T10:57:21.411177Z")))
    }

    @Test
    func `decodes plain JSON, as in the token file`() throws {
        let credentials = try AntigravityCredentials.parse(Data((json + "\n").utf8))
        #expect(credentials.accessToken == "test-access-token")
    }

    @Test
    func `decodes a bare token object`() throws {
        let credentials = try AntigravityCredentials.parse(Data(#"{"access_token": "bare", "expiry": "2026-11-24T10:00:00Z"}"#.utf8))
        #expect(credentials.accessToken == "bare")
        #expect(credentials.expiresAt == (try Fixture.date("2026-11-24T10:00:00Z")))
    }

    @Test(arguments: [
        #"{"token": {"access_token": "t"}}"#,
        #"{"token": {"access_token": "t", "expiry": "0001-01-01T00:00:00Z"}}"#,
        #"{"token": {"access_token": "t", "expiry": "soon"}}"#,
    ])
    func `a missing or zero expiry means no known expiry`(json: String) throws {
        let credentials = try AntigravityCredentials.parse(Data(json.utf8))
        #expect(credentials.expiresAt == nil)
        #expect(!credentials.isExpired(at: now))
    }

    @Test(arguments: [
        "go-keyring-base64:not base64!",
        "go-keyring-base64:" + Data("not json".utf8).base64EncodedString(),
        #"{"token": {"access_token": ""}}"#,
        #"{"token": {"refresh_token": "r"}}"#,
        #"{"auth_method": "consumer"}"#,
        "",
    ])
    func `values without an access token mean not logged in`(value: String) {
        #expect(throws: UsageError.notLoggedIn(AntigravityCredentials.notLoggedInMessage)) {
            try AntigravityCredentials.parse(Data(value.utf8))
        }
    }

    @Test
    func `a token is expired from its expiry on`() throws {
        let credentials = try AntigravityCredentials.parse(keyringValue(json))
        let expiry = try #require(credentials.expiresAt)

        #expect(!credentials.isExpired(at: expiry.addingTimeInterval(-1)))
        #expect(credentials.isExpired(at: expiry))
    }

    @Test
    func `reads the gemini item for the antigravity account`() async throws {
        let runner = FakeRunner(results: [.exited(status: 0, output: keyringValue(json))])
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let data = try await AntigravityCredentials.read(tokenFile: file, run: runner.run)

        #expect(try AntigravityCredentials.parse(data).accessToken == "test-access-token")
        #expect(runner.calls.map(\.arguments) == [["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"]])
        #expect(runner.calls.first?.executable.path == "/usr/bin/security")
        #expect(runner.calls.first?.timeout == .seconds(60))
    }

    @Test
    func `falls back to the token file when the Keychain has no item`() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data(json.utf8).write(to: file)
        let runner = FakeRunner(results: [.exited(status: 44, output: Data())])
        let data = try await AntigravityCredentials.read(tokenFile: file, run: runner.run)

        #expect(try AntigravityCredentials.parse(data).accessToken == "test-access-token")
    }

    @Test
    func `no Keychain item and no token file means not logged in`() async {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let runner = FakeRunner(results: [.exited(status: 44, output: Data())])
        await #expect(throws: UsageError.notLoggedIn(AntigravityCredentials.notLoggedInMessage)) {
            try await AntigravityCredentials.read(tokenFile: file, run: runner.run)
        }
    }

    @Test
    func `other Keychain errors don't fall back to the file`() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data(json.utf8).write(to: file)
        let runner = FakeRunner(results: [.timedOut])
        await #expect(throws: UsageError.keychainTimedOut) {
            try await AntigravityCredentials.read(tokenFile: file, run: runner.run)
        }
    }

    @Test
    func `the token file is in the agy data directory`() {
        let home = URL(filePath: "/Users/someone")
        #expect(AntigravityHome.tokenFile(home: home).path == "/Users/someone/.gemini/antigravity-cli/antigravity-oauth-token")
    }

    @Test
    func `CLI candidates are in the documented order`() {
        let home = URL(filePath: "/Users/someone")
        #expect(AntigravityHome.cliCandidates(home: home).map(\.path) == [
            "/Users/someone/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ])
    }
}
