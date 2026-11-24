import Foundation
import Testing

@testable import AIUsageKit

struct MenuBarUsageTests {
    private let weekly = UsageLimit(name: "Weekly", percentUsed: 85.4, resetsAt: nil, severity: nil, role: .overallWeekly)
    private let scoped = UsageLimit(name: "Fable", percentUsed: 73, resetsAt: nil, severity: nil)
    private let fiveHour = UsageLimit(name: "5-hour", percentUsed: 12, resetsAt: nil, severity: nil)

    @Test
    func `shows the overall weekly limit, not a scoped or other one`() {
        #expect(MenuBarUsage.weeklyPercent(limits: [fiveHour, scoped, weekly]) == 85)
    }

    @Test
    func `ignores a limit that is only named Weekly`() {
        let lookalike = UsageLimit(name: "Weekly", percentUsed: 50, resetsAt: nil, severity: nil)
        #expect(MenuBarUsage.weeklyPercent(limits: [lookalike]) == nil)
    }

    @Test
    func `rounds as the panel does`() {
        for (value, expected) in [(0.4, 0), (8.5, 9), (9, 9), (85.5, 86), (99.6, 100), (120, 120)] {
            let limit = UsageLimit(name: "Weekly", percentUsed: value, resetsAt: nil, severity: nil, role: .overallWeekly)
            #expect(MenuBarUsage.weeklyPercent(limits: [limit]) == expected)
            #expect(UsageFormat.percent(value) == "\(expected)%")
        }
    }

    @Test
    func `finds the weekly limits of Codex and Antigravity by their IDs`() throws {
        let codex = try CodexUsageParser.parse(Fixture.data("codex-usage"), now: Date(timeIntervalSince1970: 0))
        let antigravity = try AntigravityUsageParser.parse(Fixture.data("antigravity-quota"))
        #expect(MenuBarUsage.weeklyPercent(limits: codex) == 5)
        #expect(MenuBarUsage.weeklyPercent(limits: antigravity) == 2)
    }

    @Test
    func `has no number before the first fetch`() {
        #expect(MenuBarUsage.weeklyPercent(limits: []) == nil)
    }

    @Test
    func `has no number when there is no weekly limit`() {
        #expect(MenuBarUsage.weeklyPercent(limits: [fiveHour, scoped]) == nil)
    }

    @Test
    func `label is always two characters`() {
        for (percent, expected) in [
            (0, "00"), (1, "01"), (9, "09"), (10, "10"), (86, "86"), (99, "99"),
            (100, "XX"), (101, "XX"), (120, "XX"), (Int.max / 2, "XX"),
            (-1, "00"), (-(Int.max / 2), "00"),
        ] {
            #expect(MenuBarUsage.label(for: percent) == expected)
            #expect(MenuBarUsage.label(for: percent).count == 2)
        }
    }

    @Test
    func `shows Claude, Codex and Gemini in that order`() {
        #expect(MenuBarUsage.providers.map(\.id) == ["claude", "codex", "antigravity"])
        #expect(MenuBarUsage.providers.map(\.name) == ["Claude", "Codex", "Gemini"])
    }

    @Test
    func `a slot without a number shows two dashes`() {
        #expect(MenuBarUsage.label(for: nil) == "--")
        #expect(MenuBarUsage.label(for: Int?.some(9)) == "09")
    }

    @Test
    func `labels every slot with two characters`() {
        let slots = [
            MenuBarUsage.Slot(name: "Claude", percent: 86),
            MenuBarUsage.Slot(name: "Codex", percent: nil),
            MenuBarUsage.Slot(name: "Gemini", percent: 100),
        ]
        #expect(MenuBarUsage.labels(for: slots) == ["86", "--", "XX"])
    }

    @Test
    func `shows dashes in every slot when nothing is available`() {
        let slots = MenuBarUsage.providers.map { MenuBarUsage.Slot(name: $0.name, percent: nil) }
        #expect(MenuBarUsage.labels(for: slots) == ["--", "--", "--"])
    }

    @Test
    func `VoiceOver reads the real numbers and says when one is not available`() {
        let slots = [
            MenuBarUsage.Slot(name: "Claude", percent: 86),
            MenuBarUsage.Slot(name: "Codex", percent: 4),
            MenuBarUsage.Slot(name: "Gemini", percent: nil),
        ]
        #expect(MenuBarUsage.accessibilityDescription(for: slots) == "Claude weekly usage 86%, Codex weekly usage 4%, Gemini weekly usage not available")
        #expect(MenuBarUsage.accessibilityDescription(for: [MenuBarUsage.Slot(name: "Claude", percent: 120)]) == "Claude weekly usage 120%")
    }

    @Test
    func `label follows the same rounding as the percentage`() {
        for (value, expected) in [(0.4, "00"), (8.5, "09"), (99.4, "99"), (99.6, "XX"), (250, "XX"), (.nan, "00")] {
            let limit = UsageLimit(name: "Weekly", percentUsed: value, resetsAt: nil, severity: nil, role: .overallWeekly)
            let percent = MenuBarUsage.weeklyPercent(limits: [limit])
            #expect(percent.map(MenuBarUsage.label(for:)) == expected)
        }
    }
}
