import Foundation
import Testing

@testable import AIUsageKit

struct ISO8601Tests {
    private let base = Date(timeIntervalSince1970: 1_763_064_000) // 2025-11-13T20:00:00Z

    @Test(arguments: [
        ("2025-11-13T20:00:00Z", 0.0),
        ("2025-11-13T20:00:00+00:00", 0.0),
        ("2025-11-13T21:00:00+01:00", 0.0),
        ("2025-11-13T20:00:00.25+00:00", 0.25),
        ("2025-11-13T20:00:00.250123+00:00", 0.250123),
        ("2025-11-13T20:00:00.5Z", 0.5),
    ])
    func `parses timestamps with and without fractional seconds`(string: String, fraction: Double) throws {
        let date = try #require(ISO8601.date(from: string))
        #expect(abs(date.timeIntervalSince(base) - fraction) < 0.000_001)
    }

    @Test(arguments: ["", "tomorrow", "2025-11-13", "2025-11-13T20:00:00.+00:00"])
    func `rejects malformed timestamps`(string: String) {
        #expect(ISO8601.date(from: string) == nil)
    }
}
