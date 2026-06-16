import Foundation

/// Formats the time remaining until a usage window resets.
public enum ResetFormatter {
    /// Produces a human reset string:
    ///  - `<= 0`:     `"now"`
    ///  - `< 1 min`:  `"<1min (17:52)"`
    ///  - `< 1 hour`: `"22min (17:52)"`
    ///  - `< 24 hours`: `"3h 22min (17:52)"`  (relative + absolute 24-hour clock)
    ///  - `>= 24 hours`: `"Tue 13:00"`        (weekday + 24-hour clock)
    public static func countdown(
        resetsAt: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let interval = resetsAt.timeIntervalSince(now)
        if interval <= 0 { return "now" }

        if interval >= 24 * 3600 {
            return format(resetsAt, pattern: "EEE HH:mm", calendar: calendar, locale: locale)
        }

        let absolute = format(resetsAt, pattern: "HH:mm", calendar: calendar, locale: locale)

        if interval < 60 {
            return "<1min (\(absolute))"
        }

        let totalMinutes = Int(interval / 60)  // floor
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let relative = hours > 0 ? "\(hours)h \(minutes)min" : "\(minutes)min"
        return "\(relative) (\(absolute))"
    }

    private static func format(_ date: Date, pattern: String, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
