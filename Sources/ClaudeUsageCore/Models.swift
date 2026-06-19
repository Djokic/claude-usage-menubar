import Foundation

/// Tolerant ISO-8601 parsing. The usage API returns timestamps like
/// `2026-06-16T18:45:00Z`; some responses include fractional seconds.
enum ISO8601 {
    private static let noFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        if let date = withFraction.date(from: string) { return date }
        if let date = noFraction.date(from: string) { return date }
        // Defense-in-depth for an undocumented endpoint: if the formatters reject the
        // fractional-second precision (digit counts vary by OS version), strip it and retry.
        if let range = string.range(of: #"\.\d+"#, options: .regularExpression) {
            let stripped = string.replacingCharacters(in: range, with: "")
            if let date = noFraction.date(from: stripped) { return date }
        }
        return nil
    }

    /// Serialize a date back to the API's whole-second format (used when persisting usage).
    static func string(from date: Date) -> String {
        noFraction.string(from: date)
    }
}

/// A single usage window (e.g. the rolling 5-hour or 7-day limit).
public struct UsageWindow: Codable, Equatable, Sendable {
    /// Usage percentage, 0–100.
    public let utilization: Double
    /// When this window resets.
    public let resetsAt: Date

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    public init(utilization: Double, resetsAt: Date) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try container.decode(Double.self, forKey: .utilization)
        let raw = try container.decode(String.self, forKey: .resetsAt)
        guard let parsed = ISO8601.parse(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .resetsAt,
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp: \(raw)"
            )
        }
        resetsAt = parsed
    }

    /// Encode `resetsAt` as the same ISO-8601 string the decoder reads, so a persisted snapshot
    /// round-trips through `init(from:)` regardless of the encoder's date strategy.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(utilization, forKey: .utilization)
        try container.encode(ISO8601.string(from: resetsAt), forKey: .resetsAt)
    }
}

/// Paid extra-usage credits (add-on), when enabled.
public struct ExtraUsage: Codable, Equatable, Sendable {
    public let isEnabled: Bool
    public let monthlyLimit: Double?
    public let usedCredits: Double?
    public let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }

    public init(isEnabled: Bool, monthlyLimit: Double?, usedCredits: Double?, utilization: Double?) {
        self.isEnabled = isEnabled
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.utilization = utilization
    }
}

/// Decoded response from `GET https://api.anthropic.com/api/oauth/usage`.
///
/// Each window is optional — the API returns `null` for windows that are not
/// active for this account. The obfuscated `iguana_necktie` field is ignored.
public struct ClaudeUsage: Codable, Equatable, Sendable {
    /// Rolling 5-hour limit (the "current session"). Drives the outer ring.
    public let fiveHour: UsageWindow?
    /// Rolling 7-day limit (all models). Drives the inner ring.
    public let sevenDay: UsageWindow?
    public let sevenDayOauthApps: UsageWindow?
    public let sevenDayOpus: UsageWindow?
    public let sevenDaySonnet: UsageWindow?
    public let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }

    public init(
        fiveHour: UsageWindow?,
        sevenDay: UsageWindow?,
        sevenDayOauthApps: UsageWindow? = nil,
        sevenDayOpus: UsageWindow? = nil,
        sevenDaySonnet: UsageWindow? = nil,
        extraUsage: ExtraUsage? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOauthApps = sevenDayOauthApps
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.extraUsage = extraUsage
    }

    /// Decode from raw JSON data using the conventions above.
    public static func decode(from data: Data) throws -> ClaudeUsage {
        try JSONDecoder().decode(ClaudeUsage.self, from: data)
    }
}
