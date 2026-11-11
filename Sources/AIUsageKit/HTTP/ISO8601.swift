import Foundation

/// Lenient ISO 8601 timestamp parsing.
///
/// The usage APIs send fractional seconds with any number of digits, such as `.25` or `.250123`,
/// which the standard parsers don't reliably accept. The fraction is parsed separately.
enum ISO8601 {
    private static let style = Date.ISO8601FormatStyle()

    static func date(from string: String) -> Date? {
        var whole = string
        var fractionalSeconds = 0.0
        if let match = string.firstMatch(of: /\.(\d+)/) {
            guard let value = Double("0.\(match.1)") else {
                return nil
            }
            fractionalSeconds = value
            whole.removeSubrange(match.range)
        }
        return (try? style.parse(whole))?.addingTimeInterval(fractionalSeconds)
    }
}
