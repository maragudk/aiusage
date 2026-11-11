import Foundation
import Testing

@testable import AIUsageKit

struct CodexUsageParserTests {
    private let now = Date(timeIntervalSince1970: 1_762_873_200)

    @Test
    func `builds rows from the main and additional rate limits`() throws {
        let limits = try CodexUsageParser.parse(Fixture.data("codex-usage"), now: now)

        #expect(limits.map(\.name) == ["5-hour", "Weekly", "Code review · Weekly", "codex_other · 30-minute"])
        #expect(limits.map(\.percentUsed) == [42, 5, 10, 88])
        #expect(limits.map(\.severity) == [nil, nil, nil, nil])
        #expect(limits[0].resetsAt == Date(timeIntervalSince1970: 1_762_873_320))
        #expect(limits[3].resetsAt == Date(timeIntervalSince1970: 1_762_873_800))
        #expect(Set(limits.map(\.id)).count == 4)
    }

    @Test
    func `uses reset_after_seconds when reset_at is missing`() throws {
        let limits = try CodexUsageParser.parse(Fixture.data("codex-usage-weekly-only"), now: now)

        #expect(limits.map(\.name) == ["Weekly"])
        #expect(limits[0].percentUsed == 17.5)
        #expect(limits[0].resetsAt == now.addingTimeInterval(3_600))
    }

    @Test
    func `tolerates missing fields`() throws {
        let json = #"""
        {"rate_limit": {"primary_window": {"used_percent": 3}, "secondary_window": {"limit_window_seconds": 60}},
         "additional_rate_limits": [{"rate_limit": null}, {"limit_name": "x", "rate_limit": {"primary_window": {"used_percent": 1, "limit_window_seconds": 86400}}}, "junk"]}
        """#
        let limits = try CodexUsageParser.parse(Data(json.utf8), now: now)

        #expect(limits.map(\.name) == ["Primary", "x · Daily"])
        #expect(limits[0].resetsAt == nil)
    }

    @Test
    func `huge window lengths don't trap`() throws {
        let json = #"{"rate_limit": {"primary_window": {"used_percent": 1, "limit_window_seconds": 1e300, "reset_at": 1e300}}}"#
        let limits = try CodexUsageParser.parse(Data(json.utf8), now: now)
        #expect(limits.map(\.name) == ["Primary"])
    }

    @Test
    func `throws when there are no windows`() {
        #expect(throws: UsageError.invalidResponse) {
            try CodexUsageParser.parse(Data(#"{"plan_type": "plus", "rate_limit": null}"#.utf8), now: now)
        }
    }

    @Test(arguments: [
        (18_000, "5-hour"),
        (604_800, "Weekly"),
        (86_400, "Daily"),
        (172_800, "2-day"),
        (3_600, "1-hour"),
        (1_800, "30-minute"),
        (45, "45-second"),
        (2_592_000, "30-day"),
    ])
    func `names windows by duration`(seconds: Int, expected: String) {
        #expect(CodexUsageParser.windowName(seconds: seconds, fallback: "Primary") == expected)
    }

    @Test(arguments: [nil, 0, -5] as [Int?])
    func `unknown durations use the fallback name`(seconds: Int?) {
        #expect(CodexUsageParser.windowName(seconds: seconds, fallback: "Secondary") == "Secondary")
    }
}
