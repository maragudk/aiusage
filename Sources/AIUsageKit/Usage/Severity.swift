/// How close a limit is to running out. Drives the colour of its bar.
public enum Severity: String, Sendable, Equatable, CaseIterable {
    case normal
    case warning
    case critical

    /// The percentage from which a limit without an API severity counts as a warning.
    public static let warningThreshold = 75.0

    /// The percentage from which a limit without an API severity counts as critical.
    public static let criticalThreshold = 90.0

    /// A severity from the percentage used, for APIs that don't report one.
    public init(percentUsed: Double) {
        self = if percentUsed >= Self.criticalThreshold {
            .critical
        } else if percentUsed >= Self.warningThreshold {
            .warning
        } else {
            .normal
        }
    }

    /// A severity as reported by an API, or nil if the value is missing or unknown.
    public init?(apiValue: String?) {
        guard let apiValue, let severity = Self(rawValue: apiValue.lowercased()) else {
            return nil
        }
        self = severity
    }
}
