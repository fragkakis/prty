import Foundation

/// Snoozed PRs are hidden from the panel's lists until something new happens
/// on them, or until the time they were snoozed for runs out.
public enum Snooze {
    /// For snoozes that only end on new activity.
    public static let untilActivity = Date.distantFuture

    /// The snoozes left after a poll: drops the ones that ran out, of PRs with
    /// new activity (`DiffResult.activity`), and of PRs no longer listed.
    public static func remaining(_ snoozed: [String: Date], activity: Set<String>, listed: Set<String>, now: Date) -> [String: Date] {
        snoozed.filter { id, until in until > now && !activity.contains(id) && listed.contains(id) }
    }

    /// 9:00 the next day.
    public static func tomorrowMorning(after now: Date, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
    }

    /// 9:00 on the next Monday, a week from today when today is Monday.
    public static func nextWeek(after now: Date, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let monday = DateComponents(hour: 9, minute: 0, weekday: 2)
        return calendar.nextDate(after: tomorrow, matching: monday, matchingPolicy: .nextTime)!
    }
}
