/// What the menu bar item shows in place of its icon.
public enum MenuBarUsage {
    /// The percentage of Claude's overall weekly limit used, rounded as in the panel, or nil when `limits` has no
    /// such limit.
    ///
    /// The menu bar keeps showing the latest value after an error, so the caller remembers the result of the last
    /// successful fetch and shows the icon only while it has none.
    public static func weeklyPercent(limits: [UsageLimit]) -> Int? {
        limits.first { $0.role == .overallWeekly }.map { UsageFormat.clampedInt($0.percentUsed) }
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
