import Foundation

/// Parses the response of `GET https://api.anthropic.com/api/oauth/usage`.
///
/// The endpoint is undocumented, so every field is optional and odd values are skipped rather than fatal.
enum ClaudeUsageParser {
    static func parse(_ data: Data) throws(UsageError) -> [UsageLimit] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw .invalidResponse
        }

        var limits = (response.limits ?? []).compactMap(\.value).enumerated().compactMap { index, limit in
            limit.usageLimit(index: index)
        }
        if limits.isEmpty {
            limits = [
                response.fiveHour?.usageLimit(id: "five_hour", name: "5-hour"),
                response.sevenDay?.usageLimit(id: "seven_day", name: "Weekly"),
            ].compactMap(\.self)
        }
        guard !limits.isEmpty else {
            throw .invalidResponse
        }
        return limits
    }

    /// The row name for a limit `kind`, with the scope's model name for scoped limits.
    static func name(kind: String?, modelName: String?) -> String {
        guard let kind, !kind.isEmpty else {
            return modelName ?? "Limit"
        }
        let lowercased = kind.lowercased()
        if lowercased == "weekly_all" {
            return "Weekly"
        }
        if lowercased == "weekly_scoped" {
            return modelName ?? "Weekly (scoped)"
        }
        let base = if ["five_hour", "5_hour", "5h", "session"].contains(where: lowercased.contains) {
            "5-hour"
        } else {
            humanize(kind)
        }
        return if let modelName { "\(base) (\(modelName))" } else { base }
    }

    /// Turns an identifier like `monthly_opus` into "Monthly opus".
    static func humanize(_ identifier: String) -> String {
        let words = identifier
            .replacing("_", with: " ")
            .replacing("-", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

private struct Response: Decodable {
    let limits: [Lossy<Limit>]?
    let fiveHour: Window?
    let sevenDay: Window?

    enum CodingKeys: String, CodingKey {
        case limits
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limits = container.lenient([Lossy<Limit>].self, forKey: .limits)
        fiveHour = container.lenient(Window.self, forKey: .fiveHour)
        sevenDay = container.lenient(Window.self, forKey: .sevenDay)
    }
}

private struct Limit: Decodable {
    let kind: String?
    let percent: Double?
    let severity: String?
    let resetsAt: String?
    let scope: Scope?

    enum CodingKeys: String, CodingKey {
        case kind, percent, severity, scope
        case resetsAt = "resets_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = container.lenient(String.self, forKey: .kind)
        percent = container.lenient(Double.self, forKey: .percent)
        severity = container.lenient(String.self, forKey: .severity)
        resetsAt = container.lenient(String.self, forKey: .resetsAt)
        scope = container.lenient(Scope.self, forKey: .scope)
    }

    func usageLimit(index: Int) -> UsageLimit? {
        guard let percent else {
            return nil
        }
        let modelName = scope?.model?.displayName
        return UsageLimit(
            id: "\(index)-\(kind ?? "")-\(modelName ?? "")",
            name: ClaudeUsageParser.name(kind: kind, modelName: modelName),
            percentUsed: percent,
            resetsAt: resetsAt.flatMap(ISO8601.date(from:)),
            severity: Severity(apiValue: severity)
        )
    }
}

private struct Scope: Decodable {
    let model: Model?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = container.lenient(Model.self, forKey: .model)
    }

    enum CodingKeys: String, CodingKey {
        case model
    }

    struct Model: Decodable {
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let name = container.lenient(String.self, forKey: .displayName)?.trimmingCharacters(in: .whitespaces)
            displayName = name?.isEmpty == false ? name : nil
        }
    }
}

private struct Window: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = container.lenient(Double.self, forKey: .utilization)
        resetsAt = container.lenient(String.self, forKey: .resetsAt)
    }

    func usageLimit(id: String, name: String) -> UsageLimit? {
        guard let utilization else {
            return nil
        }
        return UsageLimit(id: id, name: name, percentUsed: utilization, resetsAt: resetsAt.flatMap(ISO8601.date(from:)), severity: nil)
    }
}
