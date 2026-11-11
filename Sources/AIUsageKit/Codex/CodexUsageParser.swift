import Foundation

/// Parses the response of `GET https://chatgpt.com/backend-api/wham/usage`.
///
/// The shape follows the openai/codex source (`RateLimitStatusPayload`) and a live response, which also
/// has `code_review_rate_limit` with the same shape as `rate_limit`. Every field is optional.
enum CodexUsageParser {
    static func parse(_ data: Data, now: Date) throws(UsageError) -> [UsageLimit] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw .invalidResponse
        }

        let main = response.rateLimit?.usageLimits(idPrefix: "main", namePrefix: nil, now: now) ?? []
        let codeReview = response.codeReviewRateLimit?.usageLimits(idPrefix: "code-review", namePrefix: "Code review", now: now) ?? []
        let additional = (response.additionalRateLimits ?? []).compactMap(\.value).enumerated().flatMap { index, limit in
            let prefix = limit.limitName ?? limit.meteredFeature ?? "Additional"
            return limit.rateLimit?.usageLimits(idPrefix: "additional-\(index)", namePrefix: prefix, now: now) ?? []
        }
        let limits = main + codeReview + additional
        guard !limits.isEmpty else {
            throw .invalidResponse
        }
        return limits
    }

    /// Names a window by its duration, like "5-hour" or "Weekly".
    static func windowName(seconds: Int?, fallback: String) -> String {
        guard let seconds, seconds > 0 else {
            return fallback
        }
        let day = 86_400
        return switch seconds {
        case 7 * day: "Weekly"
        case day: "Daily"
        case _ where seconds.isMultiple(of: day): "\(seconds / day)-day"
        case _ where seconds.isMultiple(of: 3_600): "\(seconds / 3_600)-hour"
        case _ where seconds.isMultiple(of: 60): "\(seconds / 60)-minute"
        default: "\(seconds)-second"
        }
    }
}

private struct Response: Decodable {
    let rateLimit: RateLimit?
    let codeReviewRateLimit: RateLimit?
    let additionalRateLimits: [Lossy<AdditionalRateLimit>]?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case codeReviewRateLimit = "code_review_rate_limit"
        case additionalRateLimits = "additional_rate_limits"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimit = container.lenient(RateLimit.self, forKey: .rateLimit)
        codeReviewRateLimit = container.lenient(RateLimit.self, forKey: .codeReviewRateLimit)
        additionalRateLimits = container.lenient([Lossy<AdditionalRateLimit>].self, forKey: .additionalRateLimits)
    }
}

private struct AdditionalRateLimit: Decodable {
    let limitName: String?
    let meteredFeature: String?
    let rateLimit: RateLimit?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limitName = container.lenient(String.self, forKey: .limitName).flatMap { $0.isEmpty ? nil : $0 }
        meteredFeature = container.lenient(String.self, forKey: .meteredFeature).flatMap { $0.isEmpty ? nil : $0 }
        rateLimit = container.lenient(RateLimit.self, forKey: .rateLimit)
    }
}

private struct RateLimit: Decodable {
    let primaryWindow: Window?
    let secondaryWindow: Window?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primaryWindow = container.lenient(Window.self, forKey: .primaryWindow)
        secondaryWindow = container.lenient(Window.self, forKey: .secondaryWindow)
    }

    func usageLimits(idPrefix: String, namePrefix: String?, now: Date) -> [UsageLimit] {
        [
            primaryWindow?.usageLimit(id: "\(idPrefix)-primary", fallbackName: "Primary", namePrefix: namePrefix, now: now),
            secondaryWindow?.usageLimit(id: "\(idPrefix)-secondary", fallbackName: "Secondary", namePrefix: namePrefix, now: now),
        ].compactMap(\.self)
    }
}

private struct Window: Decodable {
    let usedPercent: Double?
    let limitWindowSeconds: Double?
    let resetAfterSeconds: Double?
    let resetAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = container.lenient(Double.self, forKey: .usedPercent)
        limitWindowSeconds = container.lenient(Double.self, forKey: .limitWindowSeconds)
        resetAfterSeconds = container.lenient(Double.self, forKey: .resetAfterSeconds)
        resetAt = container.lenient(Double.self, forKey: .resetAt)
    }

    func usageLimit(id: String, fallbackName: String, namePrefix: String?, now: Date) -> UsageLimit? {
        guard let usedPercent else {
            return nil
        }
        let seconds = limitWindowSeconds.flatMap { Int(exactly: $0.rounded()) }
        let windowName = CodexUsageParser.windowName(seconds: seconds, fallback: fallbackName)
        let name = if let namePrefix { "\(namePrefix) · \(windowName)" } else { windowName }
        let resetsAt: Date? = if let resetAt, resetAt > 0 {
            Date(timeIntervalSince1970: resetAt)
        } else if let resetAfterSeconds, resetAfterSeconds >= 0 {
            now.addingTimeInterval(resetAfterSeconds)
        } else {
            nil
        }
        return UsageLimit(id: id, name: name, percentUsed: usedPercent, resetsAt: resetsAt, severity: nil)
    }
}
