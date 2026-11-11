import Foundation

/// Text formatting for the panel.
public enum UsageFormat {
    /// A reset time relative to now, like "in 2d 4h", "in 3h 12m" or "in 12m".
    public static func relative(to date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else {
            return "now"
        }
        let minutes = clampedInt(seconds / 60)
        guard minutes > 0 else {
            return "in <1m"
        }
        let days = minutes / (24 * 60)
        let hours = minutes % (24 * 60) / 60
        return if days > 0 {
            "in \(days)d \(hours)h"
        } else if hours > 0 {
            "in \(hours)h \(minutes % 60)m"
        } else {
            "in \(minutes)m"
        }
    }

    /// A reset time as a weekday and time, like "Fri 21:00", adding the date when it is a week or more away.
    public static func absolute(_ date: Date, now: Date, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone)
        let isAWeekOrMoreAway = date.timeIntervalSince(now) >= 6.5 * 24 * 3_600
        // Day and time are formatted apart, because combined formats add words like "at" in some locales.
        let day = if isAWeekOrMoreAway {
            date.formatted(style.weekday(.abbreviated).day().month(.abbreviated))
        } else {
            date.formatted(style.weekday(.abbreviated))
        }
        let time = date.formatted(style.hour().minute())
        // Some locales put a comma after the weekday, which looks fussy in a compact row.
        return "\(day.replacing(",", with: "")) \(time)"
    }

    /// How long ago the data was fetched, like "Updated 3m ago".
    public static func updated(_ date: Date, now: Date) -> String {
        let minutes = clampedInt((now.timeIntervalSince(date) / 60).rounded(.down))
        return if minutes < 1 {
            "Updated just now"
        } else if minutes < 60 {
            "Updated \(minutes)m ago"
        } else if minutes < 24 * 60 {
            "Updated \(minutes / 60)h ago"
        } else {
            "Updated \(minutes / (24 * 60))d ago"
        }
    }

    /// A percentage as a whole number, like "85%".
    public static func percent(_ value: Double) -> String {
        "\(clampedInt(value))%"
    }

    /// Rounds to an `Int` without trapping on values out of range, which an API could send.
    static func clampedInt(_ value: Double) -> Int {
        guard value.isFinite else {
            return 0
        }
        let limit = Double(Int.max / 2)
        return Int(min(max(value.rounded(), -limit), limit))
    }
}
