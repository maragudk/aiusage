import Foundation
import Testing

@testable import AIUsageKit

struct FetchTimeoutTests {
    @Test
    func `a fast fetch returns its limits`() async throws {
        let provider = StubProvider { [UsageLimit(id: "a", name: "Weekly", percentUsed: 10, resetsAt: nil, severity: nil)] }
        let result = await provider.fetchLimits(timeout: .seconds(10))
        #expect(try result.get().map(\.name) == ["Weekly"])
    }

    @Test
    func `a failed fetch returns its error`() async {
        let provider = StubProvider { () throws(UsageError) in throw .network }
        let result = await provider.fetchLimits(timeout: .seconds(10))
        #expect(throws: UsageError.network) { try result.get() }
    }

    @Test
    func `a fetch that never finishes times out without waiting for it`() async {
        let provider = StubProvider { () throws(UsageError) in
            // Ignores cancellation, like a blocked system call.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { continuation.resume() }
            }
            return []
        }
        let start = ContinuousClock.now
        let result = await provider.fetchLimits(timeout: .milliseconds(200))
        #expect(throws: UsageError.timedOut) { try result.get() }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test
    func `a timed out fetch is cancelled`() async {
        let provider = StubProvider { () throws(UsageError) in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                throw .network
            }
            return []
        }
        let start = ContinuousClock.now
        let result = await provider.fetchLimits(timeout: .milliseconds(200))
        #expect(throws: UsageError.timedOut) { try result.get() }
        #expect(ContinuousClock.now - start < .seconds(3))
    }
}

private struct StubProvider: UsageProvider {
    let id = "stub"
    let name = "Stub"
    let isAvailable = true
    let loginRepair: LoginRepair? = nil
    let fetch: @Sendable () async throws(UsageError) -> [UsageLimit]

    func fetchLimits() async throws(UsageError) -> [UsageLimit] {
        try await fetch()
    }
}
