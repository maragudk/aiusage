import Foundation
import Testing

@testable import AIUsageKit

struct BackoffTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test
    func `a fresh backoff allows attempts`() {
        #expect(Backoff().allowsAttempt(at: now))
    }

    @Test
    func `delays double from five minutes up to an hour`() {
        var backoff = Backoff()
        var delays: [TimeInterval] = []
        for _ in 0..<6 {
            backoff.recordFailure(at: now, retryAfter: nil)
            delays.append(backoff.notBefore?.timeIntervalSince(now) ?? 0)
        }
        #expect(delays == [300, 600, 1_200, 2_400, 3_600, 3_600])
    }

    @Test
    func `attempts are blocked until the delay has passed`() {
        var backoff = Backoff()
        backoff.recordFailure(at: now, retryAfter: nil)
        #expect(!backoff.allowsAttempt(at: now.addingTimeInterval(299)))
        #expect(backoff.allowsAttempt(at: now.addingTimeInterval(300)))
    }

    @Test
    func `retry after is honoured when it is longer`() {
        var backoff = Backoff()
        backoff.recordFailure(at: now, retryAfter: 900)
        #expect(backoff.notBefore == now.addingTimeInterval(900))
    }

    @Test
    func `retry after is capped at an hour`() {
        var backoff = Backoff()
        backoff.recordFailure(at: now, retryAfter: 86_400)
        #expect(backoff.notBefore == now.addingTimeInterval(3_600))
    }

    @Test
    func `success resets the backoff`() {
        var backoff = Backoff()
        backoff.recordFailure(at: now, retryAfter: nil)
        backoff.recordFailure(at: now, retryAfter: nil)
        backoff.recordSuccess()
        #expect(backoff.allowsAttempt(at: now))
        backoff.recordFailure(at: now, retryAfter: nil)
        #expect(backoff.notBefore == now.addingTimeInterval(300))
    }
}
