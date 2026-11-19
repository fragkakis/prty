import Foundation
import Testing
@testable import PRtyTimeCore

@Suite struct ChecksTests {
    func checks(_ state: CheckState?, head: String = "c1", conflicting: Bool = false) -> [String: MergeStatus] {
        ["A": MergeStatus(checks: state, conflicting: conflicting, headOid: head)]
    }

    /// Polls my PR "A" once per step, with that step's checks lookup; returns the last diff.
    func run(_ steps: [(pr: PullRequest, checks: [String: MergeStatus]?)], settings: DiffSettings = DiffSettings(now: now)) -> DiffResult {
        var snapshot: Snapshot?
        var result: DiffResult?
        for step in steps {
            let data = PollData(viewer: me, buckets: [.mine: [step.pr]], mergeStatus: step.checks)
            result = ActivityDiff.run(previous: snapshot, poll: data, settings: settings)
            snapshot = result?.snapshot
        }
        return result!
    }

    func run(_ steps: [[String: MergeStatus]?], settings: DiffSettings = DiffSettings(now: now)) -> DiffResult {
        run(steps.map { (pr("A", author: me), $0) }, settings: settings)
    }

    @Test func failingChecksOnMyPRNotifyWithoutADot() {
        for before in [checks(.pending), checks(.passing), checks(nil)] {
            let result = run([before, checks(.failing)])
            #expect(result.notifications.map(\.body) == ["Checks failed"])
            #expect(result.notifications.first?.url.absoluteString == "https://github.com/o/repo/pull/1/checks")
            #expect(result.snapshot.unread.isEmpty)
        }
    }

    @Test func checksAlreadyFailingWhenFirstFetchedDontNotify() {
        // Checks just turned on: the poll before didn't fetch them.
        #expect(run([[:], checks(.failing)]).notifications.isEmpty)
    }

    @Test func stillFailingDoesntRenotifyButANewCommitFailingDoes() {
        #expect(run([checks(.pending), checks(.failing), checks(.failing)]).notifications.isEmpty)
        #expect(run([checks(.failing), checks(.failing, head: "c2")]).notifications.map(\.body) == ["Checks failed"])
    }

    @Test func failedLookupKeepsTheLastChecks() {
        #expect(run([checks(.passing), nil, checks(.failing)]).notifications.map(\.body) == ["Checks failed"])
        #expect(run([checks(.failing), nil, checks(.failing)]).notifications.isEmpty)
        #expect(run([checks(.passing), nil]).snapshot.prs["A"]?.checks == .passing)
    }

    @Test func checksTurnedOffForgetTheLastChecks() {
        let snapshot = run([checks(.passing), [:]]).snapshot
        #expect(snapshot.prs["A"]?.checks == nil && snapshot.prs["A"]?.checksOid == nil)
    }

    @Test func respectsTheSetting() {
        let settings = DiffSettings(enabled: Set(NotificationCategory.allCases).subtracting([.checks]), now: now)
        #expect(run([checks(.passing), checks(.failing)], settings: settings).notifications.isEmpty)
    }

    @Test func joinsOtherActivityAndLinksThePR() {
        let reviewed = pr("A", author: me, reviews: [review("r1", "APPROVED", by: "bob")])
        let result = run([(pr("A", author: me), checks(.passing)), (reviewed, checks(.failing))])
        #expect(result.notifications.map(\.body) == ["bob approved · Checks failed"])
        #expect(result.notifications.first?.url.absoluteString == "https://github.com/o/repo/pull/1")
        #expect(result.snapshot.unread == ["A"])
    }

    @Test func onlyMyPRsNotify() {
        var snapshot: Snapshot?
        for state in [CheckState.passing, .failing] {
            let data = PollData(viewer: me, buckets: [.reviewed: [pr("A")]], mergeStatus: checks(state))
            let result = ActivityDiff.run(previous: snapshot, poll: data, settings: DiffSettings(now: now))
            snapshot = result.snapshot
            #expect(result.notifications.isEmpty)
        }
    }
}
