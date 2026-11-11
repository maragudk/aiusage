import Foundation
import Testing

@testable import AIUsageKit

struct UsageFormatTests {
    private let now = Date(timeIntervalSince1970: 1_762_862_400) // 2025-11-11T12:00:00Z, a Tuesday

    @Test(arguments: [
        (2 * 86_400 + 4 * 3_600 + 10 * 60.0, "in 2d 4h"),
        (86_400.0, "in 1d 0h"),
        (3 * 3_600 + 12 * 60.0, "in 3h 12m"),
        (12 * 60.0, "in 12m"),
        (29.0, "in <1m"),
        (0.0, "now"),
        (-60.0, "now"),
    ] as [(TimeInterval, String)])
    func `relative reset times`(offset: TimeInterval, expected: String) {
        #expect(UsageFormat.relative(to: now.addingTimeInterval(offset), now: now) == expected)
    }

    @Test
    func `relative time rounds to the nearest minute`() {
        #expect(UsageFormat.relative(to: now.addingTimeInterval(59 * 60 + 40), now: now) == "in 1h 0m")
    }

    @Test
    func `absolute reset time within a week shows weekday and time`() {
        let reset = now.addingTimeInterval(3 * 86_400 + 9 * 3_600) // Friday 21:00 UTC
        #expect(UsageFormat.absolute(reset, now: now, locale: Locale(identifier: "en_GB"), timeZone: .gmt) == "Fri 21:00")
    }

    @Test
    func `absolute reset time a week or more away also shows the date`() {
        let reset = now.addingTimeInterval(8 * 86_400)
        #expect(UsageFormat.absolute(reset, now: now, locale: Locale(identifier: "en_GB"), timeZone: .gmt) == "Wed 19 Nov 12:00")
    }

    @Test(arguments: [
        (10.0, "Updated just now"),
        (59.0, "Updated just now"),
        (60.0, "Updated 1m ago"),
        (45 * 60.0, "Updated 45m ago"),
        (2 * 3_600 + 5 * 60.0, "Updated 2h ago"),
        (3 * 86_400.0, "Updated 3d ago"),
    ] as [(TimeInterval, String)])
    func `updated ago`(age: TimeInterval, expected: String) {
        #expect(UsageFormat.updated(now.addingTimeInterval(-age), now: now) == expected)
    }

    @Test(arguments: [(85.0, "85%"), (72.6, "73%"), (0.4, "0%"), (100.0, "100%")])
    func `percentages are whole numbers`(percent: Double, expected: String) {
        #expect(UsageFormat.percent(percent) == expected)
    }
}
