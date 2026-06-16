import Testing
import Foundation
@testable import ClaudeUsageCore

@Suite struct ModelsTests {
    // Covers R6: decode a full payload with both required windows present.
    @Test func decodesFullPayload() throws {
        let json = """
        {
          "five_hour": { "utilization": 19, "resets_at": "2026-06-16T18:45:00Z" },
          "seven_day": { "utilization": 3, "resets_at": "2026-06-23T13:00:00Z" },
          "seven_day_oauth_apps": null,
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "iguana_necktie": null,
          "extra_usage": null
        }
        """.data(using: .utf8)!

        let usage = try ClaudeUsage.decode(from: json)
        #expect(usage.fiveHour?.utilization == 19)
        #expect(usage.sevenDay?.utilization == 3)

        let expectedReset = ISO8601.parse("2026-06-16T18:45:00Z")
        #expect(usage.fiveHour?.resetsAt == expectedReset)
        #expect(usage.sevenDayOauthApps == nil)
        #expect(usage.extraUsage == nil)
    }

    @Test func decodesWithNullWindows() throws {
        let json = """
        {
          "five_hour": { "utilization": 50, "resets_at": "2026-06-16T18:45:00Z" },
          "seven_day": null,
          "seven_day_oauth_apps": null,
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "extra_usage": null
        }
        """.data(using: .utf8)!

        let usage = try ClaudeUsage.decode(from: json)
        #expect(usage.fiveHour?.utilization == 50)
        #expect(usage.sevenDay == nil)
        #expect(usage.sevenDayOpus == nil)
    }

    @Test func decodesPerModelAndExtraWindows() throws {
        let json = """
        {
          "five_hour": { "utilization": 10, "resets_at": "2026-06-16T18:45:00Z" },
          "seven_day": { "utilization": 60, "resets_at": "2026-06-23T13:00:00Z" },
          "seven_day_opus": { "utilization": 5, "resets_at": "2026-06-23T13:00:00Z" },
          "seven_day_sonnet": { "utilization": 0, "resets_at": "2026-06-23T13:00:00Z" },
          "extra_usage": { "is_enabled": true, "monthly_limit": 100, "used_credits": 12.5, "utilization": 12.5 }
        }
        """.data(using: .utf8)!

        let usage = try ClaudeUsage.decode(from: json)
        #expect(usage.sevenDayOpus?.utilization == 5)
        #expect(usage.sevenDaySonnet?.utilization == 0)
        #expect(usage.extraUsage?.isEnabled == true)
        #expect(usage.extraUsage?.monthlyLimit == 100)
        #expect(usage.extraUsage?.usedCredits == 12.5)
    }

    @Test func parsesZuluTimestampToCorrectInstant() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 16
        components.hour = 18
        components.minute = 45
        components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let expected = calendar.date(from: components)

        let date = ISO8601.parse("2026-06-16T18:45:00Z")
        #expect(date == expected)
    }

    @Test func parsesFractionalSecondsTimestamp() throws {
        let date = ISO8601.parse("2026-06-16T18:45:00.500Z")
        #expect(date != nil)
    }

    // Real API format observed live: 6-digit microseconds + "+00:00" offset (not "Z").
    @Test func parsesLiveApiTimestampFormat() throws {
        #expect(ISO8601.parse("2026-06-16T14:20:00.035238+00:00") != nil)
        #expect(ISO8601.parse("2026-06-23T11:00:00.035261+00:00") != nil)
    }

    @Test func decodesLivePayloadWithMicrosecondTimestamps() throws {
        let json = """
        {
          "five_hour": { "utilization": 33.0, "resets_at": "2026-06-16T14:20:00.035238+00:00" },
          "seven_day": { "utilization": 6.0, "resets_at": "2026-06-23T11:00:00.035261+00:00" },
          "seven_day_sonnet": { "utilization": 0.0, "resets_at": "2026-06-23T11:00:00.035272+00:00" },
          "seven_day_cowork": null, "tangelo": null, "omelette_promotional": null,
          "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null, "currency": null }
        }
        """.data(using: .utf8)!
        let usage = try ClaudeUsage.decode(from: json)
        #expect(usage.fiveHour?.utilization == 33.0)
        #expect(usage.sevenDay?.utilization == 6.0)
        #expect(usage.sevenDaySonnet?.utilization == 0.0)
        #expect(usage.extraUsage?.isEnabled == false)
    }

    @Test func throwsOnMalformedUtilization() {
        let json = """
        { "five_hour": { "utilization": "not-a-number", "resets_at": "2026-06-16T18:45:00Z" }, "seven_day": null }
        """.data(using: .utf8)!
        #expect(throws: (any Error).self) { try ClaudeUsage.decode(from: json) }
    }

    @Test func throwsOnInvalidResetTimestamp() {
        let json = """
        { "five_hour": { "utilization": 10, "resets_at": "yesterday" }, "seven_day": null }
        """.data(using: .utf8)!
        #expect(throws: (any Error).self) { try ClaudeUsage.decode(from: json) }
    }

    @Test func ignoresUnknownIguanaNecktieField() throws {
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2026-06-16T18:45:00Z" },
          "seven_day": null,
          "iguana_necktie": { "anything": [1, 2, 3] }
        }
        """.data(using: .utf8)!
        let usage = try ClaudeUsage.decode(from: json)
        #expect(usage.fiveHour?.utilization == 1)
    }
}
