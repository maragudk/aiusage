import Foundation

/// Parses the response of `POST https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`.
///
/// A live response is `{"groups": [{"displayName": "Gemini Models", "buckets": [{"bucketId": "gemini-5h",
/// "window": "5h", "remainingFraction": 0.93, "resetTime": "…"}, …]}, …]}`. Community tools also report the
/// groups wrapped in `{"response": {…}}`, and the fraction nested in `"remaining": {"remainingFraction": …}`.
/// The endpoint is undocumented, so every field is optional and odd values are skipped rather than fatal.
enum AntigravityUsageParser {
    static func parse(_ data: Data) throws(UsageError) -> [UsageLimit] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw .invalidResponse
        }

        let groups = (response.response?.groups ?? response.groups ?? []).compactMap(\.value)
        let limits = groups.enumerated().flatMap { groupIndex, group in
            let groupName = group.displayName.map(Self.groupName)
            return (group.buckets ?? []).compactMap(\.value).enumerated()
                .compactMap { bucketIndex, bucket in
                    bucket.usageLimit(id: "\(groupIndex)-\(bucketIndex)-\(bucket.bucketID ?? "")", groupName: groupName)
                }
                .enumerated()
                .sorted { ($0.element.seconds ?? .max, $0.offset) < ($1.element.seconds ?? .max, $1.offset) }
                .map(\.element.limit)
        }
        guard !limits.isEmpty else {
            throw .invalidResponse
        }
        return limits
    }

    /// A group's display name without the trailing "models", like "Gemini" for "Gemini Models".
    static func groupName(_ displayName: String) -> String {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        guard let match = name.firstMatch(of: /(?i)\s+models$/) else {
            return name
        }
        return String(name[..<match.range.lowerBound])
    }

    /// Names a window like the other providers do: "5-hour", "Weekly", "Daily".
    static func windowName(_ window: String) -> String {
        guard let seconds = seconds(of: window) else {
            return ClaudeUsageParser.humanize(window)
        }
        return CodexUsageParser.windowName(seconds: seconds, fallback: window)
    }

    /// The length of a window like `5h`, `30m`, `7d`, `weekly` or `daily`, or nil if it isn't one of those.
    static func seconds(of window: String) -> Int? {
        let window = window.lowercased()
        switch window {
        case "weekly": return 7 * 86_400
        case "daily": return 86_400
        case "hourly": return 3_600
        default: break
        }
        guard let match = window.wholeMatch(of: /(\d{1,6})\s*([smhdw])/), let count = Int(match.1) else {
            return nil
        }
        let unit = switch match.2 {
        case "s": 1
        case "m": 60
        case "h": 3_600
        case "d": 86_400
        default: 7 * 86_400
        }
        return count * unit
    }
}

private struct Response: Decodable {
    let response: Groups?
    let groups: [Lossy<Group>]?

    struct Groups: Decodable {
        let groups: [Lossy<Group>]?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            groups = container.lenient([Lossy<Group>].self, forKey: .groups)
        }

        enum CodingKeys: String, CodingKey {
            case groups
        }
    }

    enum CodingKeys: String, CodingKey {
        case response, groups
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        response = container.lenient(Groups.self, forKey: .response)
        groups = container.lenient([Lossy<Group>].self, forKey: .groups)
    }
}

private struct Group: Decodable {
    let displayName: String?
    let buckets: [Lossy<Bucket>]?

    enum CodingKeys: String, CodingKey {
        case displayName, buckets
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = container.lenient(String.self, forKey: .displayName).flatMap { $0.isEmpty ? nil : $0 }
        buckets = container.lenient([Lossy<Bucket>].self, forKey: .buckets)
    }
}

private struct Bucket: Decodable {
    let bucketID: String?
    let displayName: String?
    let window: String?
    let remainingFraction: Double?
    let resetTime: String?
    let isDisabled: Bool

    enum CodingKeys: String, CodingKey {
        case bucketID = "bucketId"
        case displayName, window, remainingFraction, remaining, resetTime, disabled
    }

    struct Remaining: Decodable {
        let remainingFraction: Double?
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bucketID = container.lenient(String.self, forKey: .bucketID)
        displayName = container.lenient(String.self, forKey: .displayName).flatMap { $0.isEmpty ? nil : $0 }
        window = container.lenient(String.self, forKey: .window).flatMap { $0.isEmpty ? nil : $0 }
        remainingFraction = container.lenient(Double.self, forKey: .remainingFraction)
            ?? container.lenient(Remaining.self, forKey: .remaining)?.remainingFraction
        resetTime = container.lenient(String.self, forKey: .resetTime)
        isDisabled = container.lenient(Bool.self, forKey: .disabled) ?? false
    }

    /// The row for this bucket and its window length for sorting, or nil if it is disabled or has no fraction.
    func usageLimit(id: String, groupName: String?) -> (limit: UsageLimit, seconds: Int?)? {
        guard !isDisabled, let remainingFraction, remainingFraction.isFinite else {
            return nil
        }
        let windowName = window.map(AntigravityUsageParser.windowName)
            ?? displayName.map { $0.replacing(/(?i)\s+remaining$/, with: "") }
            ?? bucketID
            ?? "Limit"
        let name = if let groupName { "\(groupName) · \(windowName)" } else { windowName }
        let limit = UsageLimit(
            id: id,
            name: name,
            percentUsed: (1 - min(max(remainingFraction, 0), 1)) * 100,
            resetsAt: resetTime.flatMap(ISO8601.date(from:)),
            severity: nil
        )
        return (limit, window.flatMap(AntigravityUsageParser.seconds(of:)))
    }
}
