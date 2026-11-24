import Foundation
import Testing

@testable import AIUsageKit

struct AntigravityUsageParserTests {
    @Test
    func `builds a row per Gemini bucket of a live response, shortest window first`() throws {
        let limits = try AntigravityUsageParser.parse(Fixture.data("antigravity-quota"))

        #expect(limits.map(\.name) == ["Gemini · 5-hour", "Gemini · Weekly"])
        #expect(limits.map { ($0.percentUsed * 1_000).rounded() / 1_000 } == [6.998, 1.749])
        #expect(limits.map(\.severity) == [nil, nil])
        #expect(limits.map(\.role) == [nil, .overallWeekly])
        #expect(limits[0].resetsAt == (try Fixture.date("2026-11-24T14:26:33Z")))
        #expect(limits[1].resetsAt == (try Fixture.date("2026-12-01T09:26:33Z")))
        #expect(Set(limits.map(\.id)).count == 2)
    }

    @Test
    func `leaves out third-party model buckets by their ID, whatever the group is called`() throws {
        let json = #"""
        {"groups": [
            {"displayName": "Claude and GPT models", "buckets": [{"bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.5}]},
            {"displayName": "Renamed group", "buckets": [
                {"bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.5},
                {"bucketId": "other-weekly", "window": "weekly", "remainingFraction": 0.5}
            ]}
        ]}
        """#
        let limits = try AntigravityUsageParser.parse(Data(json.utf8))
        #expect(limits.map(\.name) == ["Renamed group · Weekly"])
    }

    @Test
    func `marks only the Gemini weekly bucket as the weekly limit, by its ID`() throws {
        let json = #"""
        {"groups": [
            {"displayName": "Gemini Models", "buckets": [
                {"bucketId": "gemini-5h", "window": "weekly", "remainingFraction": 0.5},
                {"bucketId": "gemini-weekly", "window": "5h", "displayName": "Something else", "remainingFraction": 0.5}
            ]},
            {"displayName": "Gemini 4 Argon", "buckets": [{"bucketId": "argon-weekly", "window": "weekly", "remainingFraction": 0.5}]}
        ]}
        """#
        let limits = try AntigravityUsageParser.parse(Data(json.utf8))
        #expect(limits.map(\.id) == ["0-1-gemini-weekly", "0-0-gemini-5h", "1-0-argon-weekly"])
        #expect(limits.map(\.role) == [.overallWeekly, nil, nil])
    }

    @Test
    func `unwraps a response envelope and a nested remaining fraction`() throws {
        let json = #"""
        {"response": {"groups": [{"displayName": "Gemini Models", "buckets": [
            {"bucketId": "gemini-5h", "window": "5h", "remaining": {"remainingFraction": 0.25}, "resetTime": "2026-11-24T14:00:00.5Z"}
        ]}]}}
        """#
        let limits = try AntigravityUsageParser.parse(Data(json.utf8))

        #expect(limits.map(\.name) == ["Gemini · 5-hour"])
        #expect(limits.map(\.percentUsed) == [75])
        #expect(limits[0].resetsAt == (try Fixture.date("2026-11-24T14:00:00.5Z")))
    }

    @Test
    func `skips disabled buckets, odd fractions and buckets with nothing to show`() throws {
        let json = #"""
        {"groups": [{"displayName": "Gemini Models", "buckets": [
            {"bucketId": "a", "window": "5h", "remainingFraction": 0.5, "disabled": true},
            {"bucketId": "b"},
            {"bucketId": "c", "window": "5h", "remainingFraction": "lots"},
            {"bucketId": "d", "window": "weekly", "remainingFraction": 0.9, "disabled": false},
            {"bucketId": "e", "window": "5h", "disabled": true},
            {"bucketId": "f", "resetTime": "not a date"},
            "junk"
        ]}, "junk"]}
        """#
        let limits = try AntigravityUsageParser.parse(Data(json.utf8))

        #expect(limits.map(\.name) == ["Gemini · Weekly"])
        #expect(abs(limits[0].percentUsed - 10) < 0.000_001)
    }

    @Test
    func `falls back to the nested fraction when the top-level one is not a number`() throws {
        let json = #"""
        {"groups": [{"buckets": [
            {"window": "5h", "remainingFraction": "n/a", "remaining": {"remainingFraction": 0.4}},
            {"window": "weekly", "remainingFraction": "n/a", "remaining": {}}
        ]}]}
        """#
        let limits = try AntigravityUsageParser.parse(Data(json.utf8))
        #expect(limits.map(\.name) == ["5-hour"])
        #expect(abs(limits[0].percentUsed - 60) < 0.000_001)
    }

    /// Proto3 JSON leaves out fields at their default value, so a used-up bucket has no fraction.
    @Test
    func `counts a bucket with a window or reset time but no fraction as fully used`() throws {
        let json = #"""
        {"groups": [{"displayName": "Gemini Models", "buckets": [
            {"bucketId": "gemini-5h", "window": "5h", "resetTime": "2026-11-24T14:00:00Z"},
            {"bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": null},
            {"bucketId": "gemini-daily", "displayName": "Daily Limit Remaining", "resetTime": "2026-11-25T00:00:00Z"},
            {"bucketId": "gemini-nested", "window": "30m", "remaining": {}}
        ]}]}
        """#
        let limits = try AntigravityUsageParser.parse(Data(json.utf8))

        #expect(limits.map(\.name) == ["Gemini · 30-minute", "Gemini · 5-hour", "Gemini · Weekly", "Gemini · Daily Limit"])
        #expect(limits.map(\.percentUsed) == [100, 100, 100, 100])
        #expect(limits[1].resetsAt == (try Fixture.date("2026-11-24T14:00:00Z")))
    }

    @Test
    func `shows a new group and window without code changes`() throws {
        let json = #"""
        {"groups": [
            {"displayName": "Gemini 4 Argon", "buckets": [{"bucketId": "argon-weekly", "window": "weekly", "remainingFraction": 0.4}]},
            {"buckets": [{"bucketId": "x", "window": "monthly", "remainingFraction": 1}, {"bucketId": "y", "window": "30m", "remainingFraction": 1}]},
            {"displayName": "Extra models", "buckets": [{"bucketId": "z", "displayName": "Daily Limit Remaining", "remainingFraction": 1}]}
        ]}
        """#
        let limits = try AntigravityUsageParser.parse(Data(json.utf8))

        #expect(limits.map(\.name) == ["Gemini 4 Argon · Weekly", "30-minute", "Monthly", "Extra · Daily Limit"])
        #expect(limits[0].percentUsed == 60)
        #expect(limits[1].resetsAt == nil)
    }

    @Test
    func `clamps fractions outside 0 to 1`() throws {
        let json = #"{"groups": [{"buckets": [{"window": "5h", "remainingFraction": 1.5}, {"window": "weekly", "remainingFraction": -0.5}]}]}"#
        let limits = try AntigravityUsageParser.parse(Data(json.utf8))
        #expect(limits.map(\.percentUsed) == [0, 100])
    }

    @Test(arguments: [
        #"{"groups": []}"#,
        #"{"groups": [{"displayName": "Gemini Models", "buckets": [{"window": "5h", "disabled": true, "remainingFraction": 1}]}]}"#,
        #"{"response": {}}"#,
        #"{"groups": [{"displayName": "Claude and GPT models", "buckets": [{"bucketId": "3p-5h", "window": "5h", "remainingFraction": 1}]}]}"#,
        "[]",
        "not json",
    ])
    func `throws when there is no usable bucket`(json: String) {
        #expect(throws: UsageError.invalidResponse) {
            try AntigravityUsageParser.parse(Data(json.utf8))
        }
    }

    @Test(arguments: [
        ("5h", "5-hour"),
        ("weekly", "Weekly"),
        ("WEEKLY", "Weekly"),
        ("daily", "Daily"),
        ("1h", "1-hour"),
        ("30m", "30-minute"),
        ("7d", "Weekly"),
        ("2d", "2-day"),
        ("1w", "Weekly"),
        ("monthly", "Monthly"),
        ("rolling_window", "Rolling window"),
    ])
    func `names windows like the other providers`(window: String, expected: String) {
        #expect(AntigravityUsageParser.windowName(window) == expected)
    }

    @Test(arguments: [
        ("Gemini Models", "Gemini"),
        ("Claude and GPT models", "Claude and GPT"),
        ("Gemini 4 Argon", "Gemini 4 Argon"),
        ("Models", "Models"),
        ("  Gemini Models ", "Gemini"),
    ])
    func `shortens group names`(displayName: String, expected: String) {
        #expect(AntigravityUsageParser.groupName(displayName) == expected)
    }
}
