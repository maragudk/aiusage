import Foundation

/// One usage limit of a provider, such as a weekly or 5-hour window.
public struct UsageLimit: Sendable, Equatable, Identifiable {
    /// Stable within one provider's list, so SwiftUI can tell the rows apart.
    public let id: String
    public let name: String
    public let percentUsed: Double
    public let resetsAt: Date?
    /// The severity reported by the API, if any.
    public let severity: Severity?

    public init(id: String? = nil, name: String, percentUsed: Double, resetsAt: Date?, severity: Severity?) {
        self.id = id ?? name
        self.name = name
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.severity = severity
    }

    /// The API severity if there is one, and otherwise one from the percentage thresholds.
    public var displaySeverity: Severity {
        severity ?? Severity(percentUsed: percentUsed)
    }
}
