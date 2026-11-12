import Foundation
import Synchronization
import Testing

@testable import AIUsageKit

/// Reads credentials through a fake `security` runner, so nothing here touches the real Keychain.
struct ClaudeCredentialsTests {
    private let now = Date(timeIntervalSince1970: 1_762_862_400)
    private let json = #"{"claudeAiOauth": {"accessToken": "test-access-token", "expiresAt": 1762866000000}}"#

    @Test
    func `reads the item with the security tool, by service and account, with a timeout`() async throws {
        let runner = FakeRunner(results: [.exited(status: 0, output: Data((json + "\n").utf8))])
        let data = try await ClaudeCredentials.readFromKeychain(account: "test-user", run: runner.run)

        #expect(data == Data(json.utf8))
        let call = try #require(runner.calls.first)
        #expect(call.executable.path == "/usr/bin/security")
        #expect(call.arguments == ["find-generic-password", "-s", "Claude Code-credentials", "-a", "test-user", "-w"])
        #expect(call.timeout == .seconds(60))
    }

    @Test
    func `falls back to any account when the user's account has no item`() async throws {
        let runner = FakeRunner(results: [
            .exited(status: 44, output: Data()),
            .exited(status: 0, output: Data(json.utf8)),
        ])
        let data = try await ClaudeCredentials.readFromKeychain(account: "test-user", run: runner.run)

        #expect(data == Data(json.utf8))
        #expect(runner.calls.map(\.arguments) == [
            ["find-generic-password", "-s", "Claude Code-credentials", "-a", "test-user", "-w"],
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
        ])
    }

    @Test
    func `decodes output that the security tool printed as hex`() async throws {
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        let runner = FakeRunner(results: [.exited(status: 0, output: Data((hex + "\n").utf8))])
        let data = try await ClaudeCredentials.readFromKeychain(account: "test-user", run: runner.run)
        #expect(data == Data(json.utf8))
    }

    @Test
    func `a missing item means not logged in`() async {
        let runner = FakeRunner(results: [.exited(status: 44, output: Data()), .exited(status: 44, output: Data())])
        await #expect(throws: UsageError.notLoggedIn(ClaudeCredentials.notLoggedInMessage)) {
            try await ClaudeCredentials.readFromKeychain(account: "test-user", run: runner.run)
        }
    }

    @Test(arguments: [
        Int32(51), // errSecAuthFailed: the user clicked Deny
        Int32(128), // errSecUserCanceled
    ])
    func `a denied prompt means access denied`(status: Int32) async {
        let runner = FakeRunner(results: [.exited(status: status, output: Data())])
        await #expect(throws: UsageError.keychainDenied) {
            try await ClaudeCredentials.readFromKeychain(account: "test-user", run: runner.run)
        }
        #expect(runner.calls.count == 1)
    }

    @Test
    func `another exit status is a Keychain read failure with that status`() async {
        let runner = FakeRunner(results: [.exited(status: 36, output: Data())])
        await #expect(throws: UsageError.keychainReadFailed(status: 36)) {
            try await ClaudeCredentials.readFromKeychain(account: "test-user", run: runner.run)
        }
    }

    @Test
    func `a read that takes too long is a Keychain timeout`() async {
        let runner = FakeRunner(results: [.timedOut])
        await #expect(throws: UsageError.keychainTimedOut) {
            try await ClaudeCredentials.readFromKeychain(account: "test-user", run: runner.run)
        }
        #expect(runner.calls.count == 1)
    }

    @Test
    func `a security tool that can't start is a tool failure`() async {
        let runner = FakeRunner(results: [.launchFailed])
        await #expect(throws: UsageError.keychainToolFailed) {
            try await ClaudeCredentials.readFromKeychain(account: "test-user", run: runner.run)
        }
    }

    @Test
    func `a token whose expiry has passed is expired`() {
        #expect(throws: UsageError.loginExpired(ClaudeProvider.expiredMessage)) {
            try ClaudeCredentials.accessToken(from: Data(json.utf8), now: Date(timeIntervalSince1970: 1_762_866_000))
        }
    }

    @Test
    func `a token whose expiry is ahead is returned`() throws {
        let token = try ClaudeCredentials.accessToken(from: Data(json.utf8), now: now)
        #expect(token == "test-access-token")
    }

    @Test(arguments: [
        UsageError.keychainDenied,
        .keychainReadFailed(status: 36),
        .keychainTimedOut,
        .keychainToolFailed,
        .notLoggedIn(ClaudeCredentials.notLoggedInMessage),
    ])
    func `Keychain errors don't say the token expired`(error: UsageError) {
        #expect(!error.message.localizedCaseInsensitiveContains("expired"))
        #expect(error.category != UsageError.loginExpired("").category)
    }
}

/// Answers each call with the next canned result and records the calls.
private final class FakeRunner: Sendable {
    struct Call {
        let executable: URL
        let arguments: [String]
        let timeout: Duration
    }

    private let state: Mutex<(results: [CommandResult], calls: [Call])>

    init(results: [CommandResult]) {
        state = Mutex((results: results, calls: []))
    }

    var calls: [Call] {
        state.withLock { $0.calls }
    }

    @Sendable
    func run(_ executable: URL, arguments: [String], timeout: Duration) async -> CommandResult {
        state.withLock { state in
            state.calls.append(Call(executable: executable, arguments: arguments, timeout: timeout))
            return state.results.isEmpty ? .launchFailed : state.results.removeFirst()
        }
    }
}
