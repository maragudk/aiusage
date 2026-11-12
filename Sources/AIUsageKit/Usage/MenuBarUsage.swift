/// What the menu bar item shows in place of its icon.
public enum MenuBarUsage {
    /// The percentage of Claude's overall weekly limit used, rounded as in the panel, or nil when the bar should
    /// show its icon instead.
    ///
    /// The panel dims its rows while the section has an error, because they are last-known data, not current.
    /// The number follows the same rule: it shows only for a section without an error.
    public static func weeklyPercent(limits: [UsageLimit], error: UsageError?) -> Int? {
        guard error == nil else {
            return nil
        }
        return limits.first { $0.role == .overallWeekly }.map { UsageFormat.clampedInt($0.percentUsed) }
    }
}
