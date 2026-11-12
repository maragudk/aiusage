import Foundation
import Synchronization
import Testing

@testable import AIUsage
@testable import AIUsageKit

/// A provider that answers from a script, one result per fetch, and counts its fetches.
private final class ScriptedProvider: UsageProvider {
    let id: String
    let name: String
    let isAvailable = true
    let loginRepair: LoginRepair? = nil
    private let results: Mutex<[Result<[UsageLimit], UsageError>]>
    private let count = Mutex(0)

    init(id: String = "claude", results: [Result<[UsageLimit], UsageError>]) {
        self.id = id
        name = id
        self.results = Mutex(results)
    }

    var fetchCount: Int {
        count.withLock { $0 }
    }

    func fetchLimits() async throws(UsageError) -> [UsageLimit] {
        count.withLock { $0 += 1 }
        let result = results.withLock { $0.isEmpty ? .success([]) : $0.removeFirst() }
        return try result.get()
    }
}

private final class Clock {
    var now = Date(timeIntervalSince1970: 1_000_000)

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

@MainActor
struct UsageStoreTests {
    private let clock = Clock()
    private let weekly = UsageLimit(name: "Weekly", percentUsed: 85.4, resetsAt: nil, severity: nil, role: .overallWeekly)

    private func makeStore(_ provider: ScriptedProvider) -> UsageStore {
        let clock = clock
        return UsageStore(providers: [provider], now: { clock.now })
    }

    @Test
    func `opening the panel during backoff does not fetch until Retry-After has passed`() async {
        let provider = ScriptedProvider(results: [
            .success([weekly]),
            .failure(.rateLimited(retryAfter: 900)),
            .success([weekly]),
        ])
        let store = makeStore(provider)

        await store.refresh(.poll)
        clock.advance(120)
        await store.refresh(.poll)
        #expect(provider.fetchCount == 2)

        // Past the 60 s panel age and the 5 minute minimum backoff, but inside Retry-After.
        clock.advance(400)
        await store.refresh(.panelOpened)
        await store.refresh(.poll)
        #expect(provider.fetchCount == 2)

        clock.advance(501)
        await store.refresh(.panelOpened)
        #expect(provider.fetchCount == 3)
    }

    @Test
    func `opening the panel soon after a fetch does not fetch`() async {
        let provider = ScriptedProvider(results: [.success([weekly])])
        let store = makeStore(provider)

        await store.refresh(.poll)
        clock.advance(30)
        await store.refresh(.panelOpened)
        #expect(provider.fetchCount == 1)

        clock.advance(61)
        await store.refresh(.panelOpened)
        #expect(provider.fetchCount == 2)
    }

    @Test
    func `a repaired login refreshes only that provider`() async {
        let claude = ScriptedProvider(id: "claude", results: [])
        let codex = ScriptedProvider(id: "codex", results: [])
        let store = UsageStore(providers: [claude, codex], now: { [clock] in clock.now })

        await store.refresh(.loginRepaired, only: "codex")
        #expect(claude.fetchCount == 0)
        #expect(codex.fetchCount == 1)
    }

    @Test
    func `the menu bar keeps the last weekly number through errors`() async {
        let provider = ScriptedProvider(results: [
            .success([weekly]),
            .failure(.rateLimited(retryAfter: nil)),
            .failure(.loginExpired("x")),
        ])
        let store = makeStore(provider)
        #expect(store.menuBarPercent == nil)

        await store.refresh(.poll)
        #expect(store.menuBarPercent == 85)

        clock.advance(10_000)
        await store.refresh(.poll)
        #expect(store.sections.first?.error == .rateLimited(retryAfter: nil))
        #expect(store.menuBarPercent == 85)

        clock.advance(10_000)
        await store.refresh(.poll)
        #expect(store.sections.first?.limits.isEmpty == true)
        #expect(store.menuBarPercent == 85)
    }

    @Test
    func `the menu bar shows the icon when the first fetch fails`() async {
        let provider = ScriptedProvider(results: [.failure(.network)])
        let store = makeStore(provider)
        await store.refresh(.poll)
        #expect(store.menuBarPercent == nil)
    }

    @Test
    func `a denied Keychain prompt is retried after the backoff`() async {
        let provider = ScriptedProvider(results: [.failure(.keychainDenied), .success([weekly])])
        let store = makeStore(provider)

        await store.refresh(.poll)
        clock.advance(299)
        await store.refresh(.poll)
        #expect(provider.fetchCount == 1)

        clock.advance(2)
        await store.refresh(.poll)
        #expect(provider.fetchCount == 2)
    }
}
