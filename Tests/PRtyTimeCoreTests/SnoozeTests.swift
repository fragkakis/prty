import Foundation
import Testing
@testable import PRtyTimeCore

@Suite struct SnoozeTests {
    let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func date(_ day: Int, _ hour: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    @Test func dropsSnoozesThatRanOutHadActivityOrLeftTheLists() {
        let snoozed = ["keep": Snooze.untilActivity, "later": now.addingTimeInterval(60), "expired": now, "active": Snooze.untilActivity, "gone": Snooze.untilActivity]
        let left = Snooze.remaining(snoozed, activity: ["active"], listed: ["keep", "later", "expired", "active"], now: now)
        #expect(Set(left.keys) == ["keep", "later"])
    }

    @Test func tomorrowMorningIsNineTheNextDay() {
        #expect(Snooze.tomorrowMorning(after: date(18, 17), calendar: utc) == date(19, 9))
        #expect(Snooze.tomorrowMorning(after: date(18, 2), calendar: utc) == date(19, 9))
    }

    @Test func nextWeekIsTheComingMondayAtNine() {
        #expect(Snooze.nextWeek(after: date(18, 17), calendar: utc) == date(23, 9)) // Wednesday
        #expect(Snooze.nextWeek(after: date(22, 20), calendar: utc) == date(23, 9)) // Sunday
        #expect(Snooze.nextWeek(after: date(23, 8), calendar: utc) == date(30, 9)) // Monday
    }

    @Test func activityIsWhatWouldGiveADot() {
        let commented = pr("A", author: me, comments: [comment("x", by: "bob")])
        #expect(diff([.mine: [pr("A", author: me)]], [.mine: [commented]]).activity == ["A"])
        #expect(diff([.team: [pr("B", details: false)]], [.direct: [pr("B")]]).activity == ["B"])
        #expect(diff([.mine: [pr("A", author: me)]], [.mine: [pr("A", author: me, comments: [comment("x", by: me)])]]).activity.isEmpty)
        // Notifications off for that kind still count.
        let quiet = DiffSettings(enabled: [], now: now)
        #expect(diff([.mine: [pr("A", author: me)]], [.mine: [commented]], settings: quiet).activity == ["A"])
    }

    @Test func checksStartingToFailCountEvenWithTheirNotificationOff() {
        let settings = DiffSettings(enabled: [], now: now)
        let mine = [Bucket.mine: [pr("A", author: me)]]
        let before = ActivityDiff.run(previous: nil, poll: PollData(viewer: me, buckets: mine, mergeStatus: ["A": MergeStatus(checks: .pending, headOid: "c1")]), settings: settings)
        let after = ActivityDiff.run(previous: before.snapshot, poll: PollData(viewer: me, buckets: mine, mergeStatus: ["A": MergeStatus(checks: .failing, headOid: "c1")]), settings: settings)
        #expect(after.activity == ["A"])
        #expect(after.notifications.isEmpty)
    }

    @Test func snoozedPRsLeaveTheListsAndTheBadge() {
        let buckets: [Bucket: [PullRequest]] = [
            .direct: [pr("D1", updated: now), pr("D2", updated: now.addingTimeInterval(-60))],
            .team: [pr("T", updated: now.addingTimeInterval(-30), details: false)],
            .reviewed: [pr("R", updated: now.addingTimeInterval(-10))],
            .mine: [pr("M1", author: me), pr("M2", author: me)],
        ]
        let sections = MenuSections(buckets: buckets, staleDays: 30, hideBots: true, snoozed: ["D1", "T", "R", "M2"], now: now)
        #expect(sections.toReview.map(\.id) == ["D2"])
        #expect(sections.badgeCount == 1)
        #expect(sections.reviewed.isEmpty)
        #expect(sections.mine.map(\.id) == ["M1"])
        #expect(sections.snoozedReview.map(\.id) == ["D1", "R", "T"])
        #expect(sections.snoozedReview.map(\.forYou) == [true, false, false])
        #expect(sections.snoozedMine.map(\.id) == ["M2"])
        #expect(sections.filtered("Title D1").snoozedReview.map(\.id) == ["D1"])
        #expect(sections.filtered("Title M").snoozedMine.map(\.id) == ["M2"])
    }
}
