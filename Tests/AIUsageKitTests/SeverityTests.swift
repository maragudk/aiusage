import Testing

@testable import AIUsageKit

struct SeverityTests {
    @Test(arguments: [
        (0.0, Severity.normal),
        (74.9, .normal),
        (75.0, .warning),
        (89.9, .warning),
        (90.0, .critical),
        (100.0, .critical),
        (130.0, .critical),
    ])
    func `percent thresholds map to severities`(percent: Double, expected: Severity) {
        #expect(Severity(percentUsed: percent) == expected)
    }

    @Test(arguments: [
        ("normal", Severity.normal),
        ("warning", .warning),
        ("critical", .critical),
        ("CRITICAL", .critical),
    ])
    func `known API severities are parsed`(value: String, expected: Severity) {
        #expect(Severity(apiValue: value) == expected)
    }

    @Test(arguments: [nil, "", "purple"])
    func `unknown API severities are nil`(value: String?) {
        #expect(Severity(apiValue: value) == nil)
    }

    @Test
    func `API severity wins over the threshold`() {
        let limit = UsageLimit(name: "Weekly", percentUsed: 95, resetsAt: nil, severity: .normal)
        #expect(limit.displaySeverity == .normal)
    }

    @Test
    func `threshold is used when the API has no severity`() {
        let limit = UsageLimit(name: "Weekly", percentUsed: 80, resetsAt: nil, severity: nil)
        #expect(limit.displaySeverity == .warning)
    }
}
