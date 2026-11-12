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

    /// The text for the menu bar: always exactly two characters, so the item's width never changes.
    ///
    /// 0 to 9 are zero-padded, 10 to 99 are unchanged, and 100 or more show `XX`. A negative value shows `00`.
    public static func label(for percent: Int) -> String {
        switch percent {
        case ..<10:
            "0\(max(percent, 0))"
        case 10..<100:
            "\(percent)"
        default:
            "XX"
        }
    }
}
