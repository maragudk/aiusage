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
    func `retry after longer than the maximum delay is honoured`() {
        var backoff = Backoff()
        backoff.recordFailure(at: now, retryAfter: 7_200)
        #expect(backoff.notBefore == now.addingTimeInterval(7_200))
    }

    @Test(arguments: [10 * 86_400, .infinity, .nan] as [TimeInterval])
    func `absurd retry after values are capped at a day`(retryAfter: TimeInterval) {
        var backoff = Backoff()
        backoff.recordFailure(at: now, retryAfter: retryAfter)
        let delay = backoff.notBefore?.timeIntervalSince(now)
        #expect(delay == 86_400 || (retryAfter.isNaN && delay == 300))
    }

    @Test
    func `many failures don't overflow`() {
        var backoff = Backoff()
        for _ in 0..<2_000 {
            backoff.recordFailure(at: now, retryAfter: nil)
        }
        #expect(backoff.notBefore == now.addingTimeInterval(3_600))
    }

    @Test(arguments: [
        ("120", 120.0),
        (" 5 ", 5.0),
        ("-3", 0.0),
        ("Wed, 21 Oct 2015 07:28:00 GMT", 60.0),
    ] as [(String, TimeInterval)])
    func `parses Retry-After as seconds or HTTP date`(value: String, expected: TimeInterval) {
        let now = Date(timeIntervalSince1970: 1_445_412_420) // 2015-10-21T07:27:00Z
        #expect(RetryAfter.seconds(from: value, now: now) == expected)
    }

    @Test(arguments: [nil, "", "soon"] as [String?])
    func `ignores missing or malformed Retry-After`(value: String?) {
        #expect(RetryAfter.seconds(from: value) == nil)
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
