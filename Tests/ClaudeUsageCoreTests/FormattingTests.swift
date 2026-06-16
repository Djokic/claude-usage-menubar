import Testing
import Foundation
@testable import ClaudeUsageCore

@Suite struct FormattingTests {
    /// Deterministic UTC / POSIX calendar so absolute times are stable.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }
    private let locale = Locale(identifier: "en_US_POSIX")

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (y, mo, d, h, mi, s)
        return calendar.date(from: c)!
    }

    // Covers R4: 5-hour reset format.
    @Test func formatsHoursAndMinutesWithAbsoluteTime() {
        let now = date(2026, 6, 16, 14, 30)
        let reset = date(2026, 6, 16, 17, 52)
        #expect(ResetFormatter.countdown(resetsAt: reset, now: now, calendar: calendar, locale: locale)
                == "3h 22min (17:52)")
    }

    @Test func formatsMinutesOnlyUnderOneHour() {
        let now = date(2026, 6, 16, 14, 30)
        let reset = date(2026, 6, 16, 14, 52)
        #expect(ResetFormatter.countdown(resetsAt: reset, now: now, calendar: calendar, locale: locale)
                == "22min (14:52)")
    }

    @Test func formatsLessThanOneMinute() {
        let now = date(2026, 6, 16, 14, 30, 0)
        let reset = date(2026, 6, 16, 14, 30, 30)
        #expect(ResetFormatter.countdown(resetsAt: reset, now: now, calendar: calendar, locale: locale)
                == "<1min (14:30)")
    }

    // Covers R5: multi-day (7-day) reset format. 2026-06-16 is a Tuesday.
    @Test func formatsWeekdayAndTimeBeyond24Hours() {
        let now = date(2026, 6, 14, 9, 0)    // Sunday, 52h before reset
        let reset = date(2026, 6, 16, 13, 0) // Tuesday 13:00
        #expect(ResetFormatter.countdown(resetsAt: reset, now: now, calendar: calendar, locale: locale)
                == "Tue 13:00")
    }

    @Test func returnsNowWhenAlreadyReset() {
        let now = date(2026, 6, 16, 14, 30)
        let reset = date(2026, 6, 16, 14, 0)
        #expect(ResetFormatter.countdown(resetsAt: reset, now: now, calendar: calendar, locale: locale) == "now")
    }

    @Test func roundsDownToWholeMinute() {
        let now = date(2026, 6, 16, 14, 30, 0)
        let reset = date(2026, 6, 16, 17, 52, 59)  // 3h 22min 59s → floor to 3h 22min
        #expect(ResetFormatter.countdown(resetsAt: reset, now: now, calendar: calendar, locale: locale)
                == "3h 22min (17:52)")
    }
}
