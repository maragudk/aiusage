import Foundation

/// Exponential backoff after rate limiting and server errors, so automatic refreshes don't hammer an API.
public struct Backoff: Sendable, Equatable {
    static let initialDelay: TimeInterval = 5 * 60
    static let maximumDelay: TimeInterval = 60 * 60

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

    /// Records a failure. A server-provided `retryAfter` is honoured when it is longer than the computed delay.
    public mutating func recordFailure(at now: Date, retryAfter: TimeInterval?) {
        failures += 1
        let exponential = Self.initialDelay * pow(2, Double(failures - 1))
        let delay = min(max(exponential, retryAfter ?? 0), Self.maximumDelay)
        notBefore = now.addingTimeInterval(delay)
    }

    public mutating func recordSuccess() {
        self = Backoff()
    }
}
