import Foundation

/// Exponential backoff after rate limiting and server errors, so automatic refreshes don't hammer an API.
public struct Backoff: Sendable, Equatable {
    static let initialDelay: TimeInterval = 5 * 60
    static let maximumDelay: TimeInterval = 60 * 60
    /// A server's `Retry-After` is honoured up to this, to guard against absurd values.
    static let maximumRetryAfter: TimeInterval = 24 * 60 * 60

    public private(set) var failures = 0
    /// No automatic attempt should be made before this time.
    public private(set) var notBefore: Date?

    public init() {}

    public func allowsAttempt(at now: Date) -> Bool {
        guard let notBefore else {
            return true
        }
        return now >= notBefore
    }

    /// Records a failure. The delay doubles from 5 minutes up to an hour, and a longer server-provided
    /// `retryAfter` is honoured.
    public mutating func recordFailure(at now: Date, retryAfter: TimeInterval?) {
        failures += 1
        let exponential = min(Self.initialDelay * pow(2, Double(min(failures - 1, 16))), Self.maximumDelay)
        let requested = retryAfter.flatMap { $0.isNaN ? nil : min(max($0, 0), Self.maximumRetryAfter) } ?? 0
        notBefore = now.addingTimeInterval(max(exponential, requested))
    }

    public mutating func recordSuccess() {
        self = Backoff()
    }
}
