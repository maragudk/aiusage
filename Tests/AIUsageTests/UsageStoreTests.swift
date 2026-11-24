import Foundation
import Synchronization
import Testing

@testable import AIUsage
@testable import AIUsageKit

/// A provider that answers from a script, one result per fetch, and counts its fetches.
private final class ScriptedProvider: UsageProvider {
    let id: String
    let name: String
    let loginRepair: LoginRepair? = nil
    private let results: Mutex<[Result<[UsageLimit], UsageError>]>
    private let count = Mutex(0)
    private let available = Mutex(true)

    init(id: String = "claude", results: [Result<[UsageLimit], UsageError>]) {
        self.id = id
        name = id
        self.results = Mutex(results)
    }

    var fetchCount: Int {
        count.withLock { $0 }
    }

    var isAvailable: Bool {
        available.withLock { $0 }
    }

    func setAvailable(_ isAvailable: Bool) {
        available.withLock { $0 = isAvailable }
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

    private func limit(_ percent: Double, role: UsageLimit.Role? = nil) -> UsageLimit {
        UsageLimit(name: "Limit", percentUsed: percent, resetsAt: nil, severity: nil, role: role)
    }

    private func makeStore(_ provider: ScriptedProvider) -> UsageStore {
        let clock = clock
        return UsageStore(providers: [provider], now: { clock.now })
    }

    @Test
    func `polls during backoff do not fetch until Retry-After has passed`() async {
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

        // Every poll inside Retry-After is skipped, also past the 5 minute minimum backoff.
        for _ in 0..<7 {
            clock.advance(120)
            await store.refresh(.poll)
        }
        #expect(provider.fetchCount == 2)

        clock.advance(120)
        await store.refresh(.poll)
        #expect(provider.fetchCount == 3)
    }

    @Test
    func `polls back off exponentially from five minutes after repeated failures`() async {
        let provider = ScriptedProvider(results: [
            .failure(.rateLimited(retryAfter: nil)),
            .failure(.rateLimited(retryAfter: nil)),
            .success([weekly]),
        ])
        let store = makeStore(provider)

        await store.refresh(.poll)
        clock.advance(299)
        await store.refresh(.poll)
        #expect(provider.fetchCount == 1)

        clock.advance(1)
        await store.refresh(.poll)
        #expect(provider.fetchCount == 2)

        // The second failure doubles the wait to 10 minutes.
        clock.advance(599)
        await store.refresh(.poll)
        #expect(provider.fetchCount == 2)

        clock.advance(1)
        await store.refresh(.poll)
        #expect(provider.fetchCount == 3)
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
        #expect(store.menuBarSlots.map(\.percent) == [nil, nil, nil])

        await store.refresh(.poll)
        #expect(store.menuBarSlots.map(\.percent) == [85, nil, nil])

        clock.advance(10_000)
        await store.refresh(.poll)
        #expect(store.sections.first?.error == .rateLimited(retryAfter: nil))
        #expect(store.menuBarSlots.map(\.percent) == [85, nil, nil])

        clock.advance(10_000)
        await store.refresh(.poll)
        #expect(store.sections.first?.limits.isEmpty == true)
        #expect(store.menuBarSlots.map(\.percent) == [85, nil, nil])
    }

    @Test
    func `the menu bar shows dashes when the first fetch fails`() async {
        let provider = ScriptedProvider(results: [.failure(.network)])
        let store = makeStore(provider)
        await store.refresh(.poll)
        #expect(store.menuBarSlots.map(\.percent) == [nil, nil, nil])
    }

    @Test
    func `the menu bar shows each provider's weekly number in a fixed order`() async {
        let antigravity = ScriptedProvider(id: "antigravity", results: [.success([limit(17, role: .overallWeekly), limit(60)])])
        let codex = ScriptedProvider(id: "codex", results: [.success([limit(42, role: .overallWeekly)])])
        let claude = ScriptedProvider(id: "claude", results: [.success([limit(73), weekly])])
        let store = UsageStore(providers: [antigravity, codex, claude], now: { [clock] in clock.now })

        await store.refresh(.poll)
        #expect(store.menuBarSlots.map(\.name) == ["Claude", "Codex", "Gemini"])
        #expect(store.menuBarSlots.map(\.percent) == [85, 42, 17])
    }

    @Test
    func `each menu bar number survives its own provider's errors`() async {
        let claude = ScriptedProvider(id: "claude", results: [.success([weekly]), .failure(.keychainTimedOut)])
        let codex = ScriptedProvider(id: "codex", results: [.success([limit(42, role: .overallWeekly)]), .failure(.network)])
        let antigravity = ScriptedProvider(id: "antigravity", results: [.success([limit(17, role: .overallWeekly)]), .failure(.loginExpired("x"))])
        let store = UsageStore(providers: [claude, codex, antigravity], now: { [clock] in clock.now })

        await store.refresh(.poll)
        clock.advance(10_000)
        await store.refresh(.poll)
        #expect(antigravity.fetchCount == 2)
        #expect(store.menuBarSlots.map(\.percent) == [85, 42, 17])
    }

    @Test
    func `a response without a weekly limit clears that provider's number`() async {
        let codex = ScriptedProvider(id: "codex", results: [.success([limit(42, role: .overallWeekly)]), .success([limit(10)])])
        let store = UsageStore(providers: [codex], now: { [clock] in clock.now })

        await store.refresh(.poll)
        #expect(store.menuBarSlots.map(\.percent) == [nil, 42, nil])

        clock.advance(120)
        await store.refresh(.poll)
        #expect(store.menuBarSlots.map(\.percent) == [nil, nil, nil])
    }

    @Test
    func `a provider that is no longer set up shows dashes, also after it is set up again`() async {
        let codex = ScriptedProvider(id: "codex", results: [.success([limit(42, role: .overallWeekly)]), .failure(.loginExpired("x"))])
        let store = UsageStore(providers: [codex], now: { [clock] in clock.now })

        await store.refresh(.poll)
        codex.setAvailable(false)
        clock.advance(120)
        await store.refresh(.poll)
        #expect(store.menuBarSlots.map(\.percent) == [nil, nil, nil])

        // Set up again, perhaps with another account, whose first fetch fails: the old number must not come back.
        codex.setAvailable(true)
        clock.advance(120)
        await store.refresh(.poll)
        #expect(codex.fetchCount == 2)
        #expect(store.menuBarSlots.map(\.percent) == [nil, nil, nil])
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
