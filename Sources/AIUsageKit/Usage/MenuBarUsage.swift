/// What the menu bar item shows: the weekly percentage of Claude, Codex and Gemini, as three two-character slots.
public enum MenuBarUsage {
    /// One number in the menu bar.
    public struct Slot: Sendable, Equatable {
        /// The name VoiceOver reads, like "Gemini".
        public let name: String
        /// The weekly percentage, or nil when there is none to show.
        public let percent: Int?

        public init(name: String, percent: Int?) {
            self.name = name
            self.percent = percent
        }
    }

    /// The providers the menu bar shows, in order: their IDs and the names VoiceOver reads. Antigravity's weekly
    /// limit is the Gemini one, so its slot is called Gemini.
    public static let providers: [(id: String, name: String)] = [
        (id: "claude", name: "Claude"),
        (id: "codex", name: "Codex"),
        (id: "antigravity", name: "Gemini"),
    ]

    /// The text of a slot without a number.
    public static let missingLabel = "--"

    /// The percentage of the provider's overall weekly limit used, rounded as in the panel, or nil when `limits`
    /// has no such limit.
    ///
    /// The menu bar keeps showing the latest value after an error, so the caller remembers the result of the last
    /// successful fetch and shows `--` only while it has none.
    public static func weeklyPercent(limits: [UsageLimit]) -> Int? {
        limits.first { $0.role == .overallWeekly }.map { UsageFormat.clampedInt($0.percentUsed) }
    }

    /// The text for one slot: always exactly two characters, so the item's width never changes.
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

    /// The text for one slot, or `--` when it has no number.
    public static func label(for percent: Int?) -> String {
        percent.map { label(for: $0) } ?? missingLabel
    }

    /// The text of each slot, in order.
    public static func labels(for slots: [Slot]) -> [String] {
        slots.map { label(for: $0.percent) }
    }

    /// What VoiceOver reads: the real numbers rather than the padded or `XX` text, like "Claude weekly usage 86%,
    /// Codex weekly usage 100%, Gemini weekly usage not available".
    public static func accessibilityDescription(for slots: [Slot]) -> String {
        slots.map { slot in
            let value = slot.percent.map { UsageFormat.percent(Double($0)) } ?? "not available"
            return "\(slot.name) weekly usage \(value)"
        }
        .joined(separator: ", ")
    }
}
