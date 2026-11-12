import Foundation
import Testing

@testable import AIUsageKit

struct MenuBarUsageTests {
    private let weekly = UsageLimit(name: "Weekly", percentUsed: 85.4, resetsAt: nil, severity: nil, role: .overallWeekly)
    private let scoped = UsageLimit(name: "Fable", percentUsed: 73, resetsAt: nil, severity: nil)
    private let fiveHour = UsageLimit(name: "5-hour", percentUsed: 12, resetsAt: nil, severity: nil)

    @Test
    func `shows the overall weekly limit, not a scoped or other one`() {
        #expect(MenuBarUsage.weeklyPercent(limits: [fiveHour, scoped, weekly], error: nil) == 85)
    }

    @Test
    func `ignores a limit that is only named Weekly`() {
        let lookalike = UsageLimit(name: "Weekly", percentUsed: 50, resetsAt: nil, severity: nil)
        #expect(MenuBarUsage.weeklyPercent(limits: [lookalike], error: nil) == nil)
    }

    @Test
    func `rounds as the panel does`() {
        for (value, expected) in [(0.4, 0), (8.5, 9), (9, 9), (85.5, 86), (99.6, 100), (120, 120)] {
            let limit = UsageLimit(name: "Weekly", percentUsed: value, resetsAt: nil, severity: nil, role: .overallWeekly)
            #expect(MenuBarUsage.weeklyPercent(limits: [limit], error: nil) == expected)
            #expect(UsageFormat.percent(value) == "\(expected)%")
        }
    }

    @Test
    func `shows the icon before the first fetch`() {
        #expect(MenuBarUsage.weeklyPercent(limits: [], error: nil) == nil)
    }

    @Test
    func `shows the icon when there is no weekly limit`() {
        #expect(MenuBarUsage.weeklyPercent(limits: [fiveHour, scoped], error: nil) == nil)
    }

    @Test
    func `shows the icon for an error that drops the data`() {
        for error in [UsageError.loginExpired("x"), .notLoggedIn("x"), .keychainDenied, .unsupported("x")] {
            #expect(MenuBarUsage.weeklyPercent(limits: [], error: error) == nil)
        }
    }

    @Test
    func `shows the icon for an error that keeps last-known data dimmed`() {
        for error in [UsageError.network, .server(status: 500), .rateLimited(retryAfter: nil), .keychainTimedOut] {
            #expect(error.keepsLastData)
            #expect(MenuBarUsage.weeklyPercent(limits: [weekly], error: error) == nil)
        }
    }
}
