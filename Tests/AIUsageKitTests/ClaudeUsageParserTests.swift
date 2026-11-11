import Foundation
import Testing

@testable import AIUsageKit

struct ClaudeUsageParserTests {
    @Test
    func `builds rows from limits in API order`() throws {
        let limits = try ClaudeUsageParser.parse(Fixture.data("claude-usage"))

        #expect(limits.map(\.name) == ["Weekly", "Fable"])
        #expect(limits.map(\.percentUsed) == [85, 73])
        #expect(limits.map(\.severity) == [.warning, .normal])
        #expect(limits[0].resetsAt == (try Fixture.date("2026-11-13T20:00:00.25+00:00")))
        #expect(limits[1].resetsAt == (try Fixture.date("2026-11-15T08:00:00.5+00:00")))
    }

    @Test
    func `row IDs are unique`() throws {
        let limits = try ClaudeUsageParser.parse(Fixture.data("claude-usage"))
        #expect(Set(limits.map(\.id)).count == limits.count)
    }

    @Test
    func `falls back to five_hour and seven_day when limits is missing`() throws {
        let limits = try ClaudeUsageParser.parse(Fixture.data("claude-usage-legacy"))

        #expect(limits.map(\.name) == ["5-hour", "Weekly"])
        #expect(limits.map(\.percentUsed) == [12.5, 85])
        #expect(limits.map(\.severity) == [nil, nil])
        #expect(limits[0].resetsAt == (try Fixture.date("2026-11-11T15:00:00Z")))
    }

    @Test
    func `falls back when limits is empty`() throws {
        let json = #"{"limits": [], "seven_day": {"utilization": 40}}"#
        let limits = try ClaudeUsageParser.parse(Data(json.utf8))
        #expect(limits.map(\.name) == ["Weekly"])
        #expect(limits[0].resetsAt == nil)
    }

    @Test
    func `a five-hour limit appears automatically`() throws {
        let json = #"""
        {"limits": [
          {"kind": "five_hour", "group": "session", "percent": 30, "severity": "normal", "resets_at": null, "scope": null},
          {"kind": "weekly_all", "group": "weekly", "percent": 50, "severity": "normal", "resets_at": null, "scope": null}
        ]}
        """#
        let limits = try ClaudeUsageParser.parse(Data(json.utf8))
        #expect(limits.map(\.name) == ["5-hour", "Weekly"])
    }

    @Test
    func `tolerates missing and odd fields`() throws {
        let json = #"""
        {"limits": [
          {"kind": "weekly_all"},
          {"percent": "lots"},
          {"kind": "weekly_scoped", "percent": 10, "severity": "sparkly", "resets_at": "soon", "scope": {"model": null}},
          {"kind": "monthly_opus_thing", "percent": 5.5, "unexpected": {"nested": [1, 2]}},
          42
        ]}
        """#
        let limits = try ClaudeUsageParser.parse(Data(json.utf8))

        #expect(limits.map(\.name) == ["Weekly (scoped)", "Monthly opus thing"])
        #expect(limits[0].severity == nil)
        #expect(limits[0].resetsAt == nil)
        #expect(limits[1].percentUsed == 5.5)
    }

    @Test
    func `throws when no limit can be found`() {
        #expect(throws: UsageError.invalidResponse) {
            try ClaudeUsageParser.parse(Data(#"{"five_hour": null, "seven_day": null}"#.utf8))
        }
    }

    @Test
    func `throws on invalid JSON`() {
        #expect(throws: UsageError.invalidResponse) {
            try ClaudeUsageParser.parse(Data("<html>".utf8))
        }
    }

    @Test(arguments: [
        ("weekly_all", nil, "Weekly"),
        ("weekly_scoped", "Fable", "Fable"),
        ("weekly_scoped", nil, "Weekly (scoped)"),
        ("five_hour", nil, "5-hour"),
        ("session", nil, "5-hour"),
        ("five_hour_all", nil, "5-hour"),
        ("monthly_all", nil, "Monthly all"),
        ("daily_scoped", "Fable", "Daily scoped (Fable)"),
        (nil, nil, "Limit"),
    ] as [(String?, String?, String)])
    func `names limits by kind`(kind: String?, model: String?, expected: String) {
        #expect(ClaudeUsageParser.name(kind: kind, modelName: model) == expected)
    }
}
