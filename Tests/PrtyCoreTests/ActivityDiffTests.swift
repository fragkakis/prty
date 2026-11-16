import Foundation
import Testing
@testable import PrtyCore

let now = Date(timeIntervalSince1970: 1_800_000_000)
let me = "fragkakis"

func pr(
    _ id: String, number: Int = 1, author: String = "alice", updated: Date = now,
    teams: [String] = [], reviews: [Review] = [], comments: [PRComment] = [],
    threadComments: [PRComment] = [], commits: [String] = ["c1"], commitAuthor: String? = "alice",
    details: Bool = true
) -> PullRequest {
    PullRequest(
        id: id, number: number, title: "Title \(id)", url: URL(string: "https://github.com/o/repo/pull/\(number)")!,
        updatedAt: updated, author: Actor(login: author), repo: "o/repo", requestedTeams: teams,
        hasDetails: details, reviews: reviews, comments: comments, threadComments: threadComments,
        commits: details ? commits.map { Commit(oid: $0, authorLogin: commitAuthor) } : []
    )
}

func review(_ id: String, _ state: String, by login: String, bot: Bool = false) -> Review {
    Review(id: id, state: state, url: URL(string: "https://github.com/o/repo/pull/1#\(id)"), author: Actor(login: login, isBot: bot))
}

func comment(_ id: String, by login: String, bot: Bool = false) -> PRComment {
    PRComment(id: id, url: URL(string: "https://github.com/o/repo/pull/1#\(id)"), author: Actor(login: login, isBot: bot))
}

func poll(_ buckets: [Bucket: [PullRequest]]) -> PollData {
    PollData(viewer: me, buckets: buckets)
}

/// Seeds with `before`, then diffs `after` against it.
func diff(_ before: [Bucket: [PullRequest]], _ after: [Bucket: [PullRequest]], settings: DiffSettings = DiffSettings(now: now)) -> DiffResult {
    let seeded = ActivityDiff.run(previous: nil, poll: poll(before), settings: settings).snapshot
    return ActivityDiff.run(previous: seeded, poll: poll(after), settings: settings)
}

@Suite struct ActivityDiffTests {
    @Test func firstRunSeedsSilently() {
        let result = ActivityDiff.run(
            previous: nil,
            poll: poll([.mine: [pr("A", author: me, comments: [comment("x", by: "bob")])], .direct: [pr("B")]]),
            settings: DiffSettings(now: now)
        )
        #expect(result.notifications.isEmpty)
        #expect(result.snapshot.prs["A"]?.seenEventIDs == ["x"])
        #expect(result.snapshot.directRequests == ["B"])
    }

    @Test func approvalOnMyPRNotifiesWithReviewURL() {
        let before = pr("A", author: me)
        let after = pr("A", author: me, reviews: [review("r1", "APPROVED", by: "bob")])
        let result = diff([.mine: [before]], [.mine: [after]])
        #expect(result.notifications.count == 1)
        #expect(result.notifications[0].body == "bob approved")
        #expect(result.notifications[0].title == "repo #1")
        #expect(result.notifications[0].url.absoluteString.hasSuffix("#r1"))
        #expect(result.snapshot.unread == ["A"])
    }

    @Test func ownAndBotActivityIsIgnored() {
        let after = pr("A", author: me, comments: [
            comment("mine", by: me),
            comment("bot1", by: "github-actions", bot: true),
            comment("bot2", by: "sonarcloud[bot]"),
        ])
        let result = diff([.mine: [pr("A", author: me)]], [.mine: [after]])
        #expect(result.notifications.isEmpty)
        #expect(result.snapshot.unread.isEmpty)
    }

    @Test func botsCountWhenNotIgnored() {
        let after = pr("A", author: me, comments: [comment("bot1", by: "github-actions", bot: true)])
        let result = diff([.mine: [pr("A", author: me)]], [.mine: [after]], settings: DiffSettings(ignoreBots: false, now: now))
        #expect(result.notifications.map(\.body) == ["github-actions commented"])
    }

    @Test func notifySelfCountsOwnActivity() {
        let after = pr("A", author: me, comments: [comment("mine", by: me)])
        let result = diff([.mine: [pr("A", author: me)]], [.mine: [after]], settings: DiffSettings(notifySelf: true, now: now))
        #expect(result.notifications.map(\.body) == ["\(me) commented"])
    }

    @Test func reviewAndThreadCommentsCollapsePerAuthor() {
        let after = pr(
            "A", author: me,
            reviews: [review("r1", "CHANGES_REQUESTED", by: "bob"), review("r2", "COMMENTED", by: "carol")],
            comments: [comment("c1", by: "dave"), comment("c2", by: "dave")],
            threadComments: [comment("t1", by: "bob"), comment("t2", by: "bob"), comment("t3", by: "carol")]
        )
        let result = diff([.mine: [pr("A", author: me)]], [.mine: [after]])
        #expect(result.notifications.count == 1)
        #expect(result.notifications[0].body == "bob requested changes (2 comments) · carol commented · dave left 2 comments")
        #expect(result.notifications[0].url.absoluteString == "https://github.com/o/repo/pull/1")
    }

    @Test func alreadySeenEventsDontRenotify() {
        let withApproval = pr("A", author: me, reviews: [review("r1", "APPROVED", by: "bob")])
        let result = diff([.mine: [withApproval]], [.mine: [withApproval]])
        #expect(result.notifications.isEmpty)
    }

    @Test func dismissedReviewsAreSkipped() {
        let after = pr("A", author: me, reviews: [review("r1", "DISMISSED", by: "bob")])
        #expect(diff([.mine: [pr("A", author: me)]], [.mine: [after]]).notifications.isEmpty)
    }

    @Test func pushesOnReviewedPRNotify() {
        let before = pr("A", commits: ["c1", "c2"])
        let after = pr("A", commits: ["c1", "c2", "c3", "c4"])
        let result = diff([.reviewed: [before]], [.reviewed: [after]])
        #expect(result.notifications.map(\.body) == ["alice pushed 2 commits"])
    }

    @Test func ownPushesAndPushesToMyPRsDontNotify() {
        let reviewed = diff(
            [.reviewed: [pr("A", commits: ["c1"], commitAuthor: me)]],
            [.reviewed: [pr("A", commits: ["c1", "c2"], commitAuthor: me)]]
        )
        #expect(reviewed.notifications.isEmpty)

        let mine = diff(
            [.mine: [pr("B", author: me, commits: ["c1"])]],
            [.mine: [pr("B", author: me, commits: ["c1", "c2"], commitAuthor: "bob")]]
        )
        #expect(mine.notifications.isEmpty)
    }

    @Test func newDirectRequestNotifies() {
        let result = diff([:], [.direct: [pr("A")]])
        #expect(result.notifications.map(\.body) == ["Review requested from you"])
        #expect(result.snapshot.unread == ["A"])
    }

    @Test func reRequestAfterReviewNotifiesWithActivity() {
        let before = pr("A", commits: ["c1"])
        let after = pr("A", commits: ["c1", "c2"])
        let result = diff([.reviewed: [before]], [.direct: [after], .reviewed: [after]])
        #expect(result.notifications.map(\.body) == ["Review re-requested from you · alice pushed 1 commit"])
    }

    @Test func requestThatLeftAndCameBackNotifiesAgain() {
        let settings = DiffSettings(now: now)
        let s1 = ActivityDiff.run(previous: nil, poll: poll([.direct: [pr("A")]]), settings: settings).snapshot
        let s2 = ActivityDiff.run(previous: s1, poll: poll([.reviewed: [pr("A")]]), settings: settings)
        #expect(s2.notifications.isEmpty)
        let s3 = ActivityDiff.run(previous: s2.snapshot, poll: poll([.direct: [pr("A")], .reviewed: [pr("A")]]), settings: settings)
        #expect(s3.notifications.map(\.body) == ["Review re-requested from you"])
    }

    @Test func freshTeamRequestNotifiesStaleDoesNot() {
        let fresh = pr("A", updated: now.addingTimeInterval(-86_400), teams: ["platform"], details: false)
        let stale = pr("B", updated: now.addingTimeInterval(-40 * 86_400), teams: ["platform"], details: false)
        let result = diff([:], [.team: [fresh, stale]])
        #expect(result.notifications.map(\.body) == ["Review requested from platform"])
        #expect(result.notifications.map(\.prID) == ["A"])
        #expect(result.snapshot.teamRequests == ["A", "B"])
    }

    @Test func botPRsDontNotifyButAreRecorded() {
        var dependabot = pr("A", details: false)
        dependabot.author = Actor(login: "dependabot", isBot: true)
        let ignoring = diff([:], [.team: [dependabot]])
        #expect(ignoring.notifications.isEmpty)
        #expect(ignoring.snapshot.unread.isEmpty)
        #expect(ignoring.snapshot.teamRequests == ["A"])

        // Turning "ignore bots" off later doesn't announce already-known bot PRs.
        let later = ActivityDiff.run(previous: ignoring.snapshot, poll: poll([.team: [dependabot]]), settings: DiffSettings(ignoreBots: false, now: now))
        #expect(later.notifications.isEmpty)

        let notIgnoring = diff([:], [.team: [dependabot]], settings: DiffSettings(ignoreBots: false, now: now))
        #expect(notIgnoring.notifications.map(\.prID) == ["A"])
    }

    @Test func staleTeamPRGettingUpdatedIsNotANewRequest() {
        let stale = pr("A", updated: now.addingTimeInterval(-40 * 86_400), details: false)
        let touched = pr("A", updated: now, details: false)
        #expect(diff([.team: [stale]], [.team: [touched]]).notifications.isEmpty)
    }

    @Test func newlyTrackedPRIsSeededNotNotified() {
        let after = pr("A", author: me, comments: [comment("c1", by: "bob")])
        let result = diff([:], [.mine: [after]])
        #expect(result.notifications.isEmpty)
        #expect(result.snapshot.prs["A"]?.seenEventIDs == ["c1"])
    }

    @Test func disabledCategoryStillMarksUnread() {
        let after = pr("A", author: me, reviews: [review("r1", "APPROVED", by: "bob")])
        let settings = DiffSettings(enabled: [.reviewRequests, .reviewing], now: now)
        let result = diff([.mine: [pr("A", author: me)]], [.mine: [after]], settings: settings)
        #expect(result.notifications.isEmpty)
        #expect(result.snapshot.unread == ["A"])
    }

    @Test func prLeavingAllListsIsForgotten() {
        let settings = DiffSettings(now: now)
        var seeded = ActivityDiff.run(previous: nil, poll: poll([.mine: [pr("A", author: me)], .direct: [pr("B")]]), settings: settings).snapshot
        seeded.unread = ["A", "B"]
        let result = ActivityDiff.run(previous: seeded, poll: poll([.direct: [pr("B")]]), settings: settings)
        #expect(result.snapshot.prs.keys.sorted() == ["B"])
        #expect(result.snapshot.unread == ["B"])
    }

    // MARK: - Merges

    func closed(_ id: String, merged: Bool = true, by mergedBy: String? = "bob", author: String = "alice", bot: Bool = false) -> ClosedPR {
        ClosedPR(id: id, number: 9, title: "Title \(id)", url: URL(string: "https://github.com/o/repo/pull/9")!,
                 repo: "o/repo", author: Actor(login: author, isBot: bot), merged: merged, mergedBy: mergedBy)
    }

    func mergeDiff(_ before: [Bucket: [PullRequest]], _ closed: [ClosedPR], settings: DiffSettings = DiffSettings(now: now)) -> DiffResult {
        let seeded = ActivityDiff.run(previous: nil, poll: poll(before), settings: settings).snapshot
        return ActivityDiff.run(previous: seeded, poll: PollData(viewer: me, buckets: [:], closed: closed), settings: settings)
    }

    @Test func missingListsPRsGoneFromEveryList() {
        let seeded = ActivityDiff.run(previous: nil, poll: poll([.mine: [pr("A", author: me)], .direct: [pr("B")], .reviewed: [pr("C")]]),
                                      settings: DiffSettings(now: now)).snapshot
        // B moved to the team list: still present. Team-only PRs aren't tracked in detail.
        #expect(seeded.missing(from: poll([.team: [pr("B", details: false)], .direct: [pr("D")]])) == ["A", "C"])
    }

    @Test func mergesOfMyAndReviewedPRsNotify() {
        let result = mergeDiff(
            [.mine: [pr("A", author: me)], .reviewed: [pr("B")], .direct: [pr("C")]],
            [closed("A", by: "bob", author: me), closed("B", by: "alice"), closed("C", merged: false, by: nil), closed("X")]
        )
        #expect(result.notifications.map(\.prID) == ["A", "B"])
        #expect(result.notifications.map(\.body) == ["Merged by bob", "Merged by alice"])
        #expect(result.notifications[0].title == "repo #9")
        #expect(result.snapshot.prs.isEmpty)
    }

    @Test func ownMergesOnlyNotifyWhenAutoMerged() {
        var auto = pr("A", author: me)
        auto.autoMerge = true
        let result = mergeDiff([.mine: [auto, pr("B", author: me)]], [closed("A", by: me, author: me), closed("B", by: me, author: me)])
        #expect(result.notifications.map(\.body) == ["Auto-merged"])
    }

    @Test func mergesRespectSettingAndBots() {
        let before: [Bucket: [PullRequest]] = [.reviewed: [pr("A"), pr("B", author: "dependabot[bot]")]]
        let merges = [closed("A"), closed("B", author: "dependabot[bot]")]
        #expect(mergeDiff(before, merges).notifications.map(\.prID) == ["A"])
        #expect(mergeDiff(before, merges, settings: DiffSettings(enabled: [.myPRs, .reviewing], now: now)).notifications.isEmpty)
    }
}
