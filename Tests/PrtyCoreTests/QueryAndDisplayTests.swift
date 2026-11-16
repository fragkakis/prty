import Foundation
import Testing
@testable import PrtyCore

@Suite struct QueriesTests {
    @Test func combinedQueryHasEveryBucket() {
        let query = Queries.build(Queries.specs.map { SearchPage(spec: $0) })
        for bucket in Bucket.allCases { #expect(query.contains("\(bucket.rawValue): search(")) }
        #expect(query.contains("fragment Full"))
        #expect(query.contains("rateLimit { cost remaining resetAt }"))
        #expect(query.contains(#"query: "is:pr is:open archived:false review-requested:@me -user-review-requested:@me", type: ISSUE, first: 100"#))
    }

    @Test func liteOnlyQueryOmitsUnusedFullFragment() {
        let team = Queries.specs.first { $0.bucket == .team }!
        let query = Queries.build([SearchPage(spec: team, after: "Y3Vyc29yOjEwMA==")])
        #expect(!query.contains("fragment Full"))
        #expect(query.contains(#"after: "Y3Vyc29yOjEwMA==""#))
    }
}

@Suite struct DecodingTests {
    @Test func decodesFullAndLiteNodes() throws {
        let json = #"""
        {"data": {
          "viewer": {"login": "fragkakis"},
          "mine": {"issueCount": 1, "pageInfo": {"hasNextPage": false, "endCursor": "x"}, "nodes": [{
            "id": "PR_1", "number": 202, "title": "Refactor", "url": "https://github.com/acme/api/pull/202",
            "isDraft": false, "updatedAt": "2026-10-22T09:50:29Z",
            "author": {"__typename": "User", "login": "fragkakis"},
            "repository": {"nameWithOwner": "acme/api"},
            "reviewRequests": {"nodes": [{"requestedReviewer": {"__typename": "Team", "slug": "platform"}}, {"requestedReviewer": {"__typename": "User", "login": "carol"}}, {"requestedReviewer": null}]},
            "reviewDecision": "APPROVED",
            "autoMergeRequest": {"enabledAt": "2026-10-22T09:00:00Z"},
            "reviews": {"nodes": [{"id": "R1", "state": "APPROVED", "url": "https://x/r1", "author": {"__typename": "User", "login": "bob"}}]},
            "comments": {"nodes": [{"id": "C1", "url": null, "author": {"__typename": "Bot", "login": "github-actions"}}]},
            "reviewThreads": {"nodes": [{"comments": {"nodes": [{"id": "T1", "url": "https://x/t1", "author": null}]}}]},
            "commits": {"nodes": [{"commit": {"oid": "a1", "author": {"user": null}}}, {"commit": {"oid": "a2", "author": {"user": {"login": "fragkakis"}}}}]}
          }]},
          "team": {"issueCount": 1, "pageInfo": {"hasNextPage": true, "endCursor": "next"}, "nodes": [{
            "id": "PR_2", "number": 7, "title": "Other", "url": "https://github.com/acme/web/pull/7",
            "isDraft": true, "updatedAt": "2026-10-01T00:00:00Z",
            "author": {"__typename": "User", "login": "alice"},
            "repository": {"nameWithOwner": "acme/web"},
            "reviewRequests": {"nodes": []}
          }]},
          "rateLimit": {"cost": 20, "remaining": 4800, "resetAt": "2026-10-22T10:00:00Z"}
        }}
        """#
        let response = try PollResponse.decode(Data(json.utf8))
        let data = try #require(response.data)
        #expect(data.viewer == "fragkakis")
        #expect(data.rateLimit?.cost == 20)

        let full = try #require(data.searches[.mine]?.nodes.first).pullRequest
        #expect(full.hasDetails)
        #expect(full.reviewDecision == .approved)
        #expect(full.requestedTeams == ["platform"])
        #expect(full.requestedUsers == ["carol"])
        #expect(full.reviews.first?.author == Actor(login: "bob"))
        #expect(full.comments.first?.author?.isBot == true)
        #expect(full.threadComments.map(\.id) == ["T1"])
        #expect(full.commits == [Commit(oid: "a1", authorLogin: nil), Commit(oid: "a2", authorLogin: "fragkakis")])
        #expect(full.headOid == "a2")
        #expect(full.repoName == "api")
        #expect(full.autoMerge)

        let lite = try #require(data.searches[.team]?.nodes.first).pullRequest
        #expect(!lite.hasDetails)
        #expect(!lite.autoMerge)
        #expect(lite.isDraft)
        #expect(data.searches[.team]?.pageInfo.endCursor == "next")
    }

    @Test func decodesClosedStatesSkippingOpenAndUnresolved() throws {
        let json = #"""
        {"data": {"nodes": [
          {"id": "PR_1", "number": 5, "title": "Done", "url": "https://github.com/o/r/pull/5", "state": "MERGED",
           "mergedBy": {"login": "bob"}, "author": {"__typename": "User", "login": "fragkakis"}, "repository": {"nameWithOwner": "o/r"}},
          {"id": "PR_2", "number": 6, "title": "Dropped", "url": "https://github.com/o/r/pull/6", "state": "CLOSED",
           "mergedBy": null, "author": null, "repository": {"nameWithOwner": "o/r"}},
          {"id": "PR_3", "number": 7, "title": "Open", "url": "https://github.com/o/r/pull/7", "state": "OPEN",
           "mergedBy": null, "author": null, "repository": {"nameWithOwner": "o/r"}},
          null
        ]}, "errors": [{"message": "Could not resolve to a node with the global id of 'PR_gone'"}]}
        """#
        let closed = try StatesResponse.decode(Data(json.utf8)).closed
        #expect(closed.map(\.id) == ["PR_1", "PR_2"])
        #expect(closed[0] == ClosedPR(id: "PR_1", number: 5, title: "Done", url: URL(string: "https://github.com/o/r/pull/5")!,
                                      repo: "o/r", author: Actor(login: "fragkakis"), merged: true, mergedBy: "bob"))
        #expect(!closed[1].merged)
    }

    @Test func statesQueryListsIds() {
        #expect(Queries.states(["PR_1", "PR_2"]).contains(#"nodes(ids: ["PR_1", "PR_2"])"#))
    }

    @Test func snapshotsSavedBeforeAutoMergeStillLoad() throws {
        let json = #"{"prs": {"A": {"seenEventIDs": ["x"], "commitOids": ["c1"]}}, "directRequests": [], "teamRequests": [], "unread": ["A"]}"#
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        #expect(snapshot.prs["A"]?.autoMerge == nil)
        #expect(snapshot.unread == ["A"])
    }

    @Test func nullDataWithErrors() throws {
        let response = try PollResponse.decode(Data(#"{"data": null, "errors": [{"message": "This may be the result of a timeout"}]}"#.utf8))
        #expect(response.data == nil)
        #expect(response.errors?.first?.message.contains("timeout") == true)
    }
}

@Suite struct DisplayTests {
    @Test func dedupsByPriorityAndFiltersStaleTeamPRs() {
        let a = pr("A", updated: now)
        let b = pr("B", updated: now.addingTimeInterval(-60))
        var otherRepo = pr("C", updated: now.addingTimeInterval(-120), details: false)
        otherRepo.repo = "o/other"
        let stale = pr("D", updated: now.addingTimeInterval(-31 * 86_400), details: false)

        let sections = MenuSections(
            buckets: [.direct: [a], .reviewed: [a, b], .team: [stale, otherRepo, a]],
            staleDays: 30, hideBots: true, now: now
        )
        #expect(sections.toReview.map(\.id) == ["A", "C"])
        #expect(sections.toReview.map(\.forYou) == [true, false])
        #expect(sections.reviewed.map(\.id) == ["B"])
        #expect(sections.badgeCount == 2)
    }

    @Test func toReviewMixesDirectAndTeamByRecency() {
        let direct = pr("A", updated: now.addingTimeInterval(-3_600))
        let newerTeam = pr("B", updated: now, details: false)
        let olderTeam = pr("C", updated: now.addingTimeInterval(-7_200), details: false)

        let sections = MenuSections(
            buckets: [.direct: [direct], .team: [olderTeam, newerTeam]],
            staleDays: 30, hideBots: true, now: now
        )
        #expect(sections.toReview.map(\.id) == ["B", "A", "C"])
        #expect(sections.toReview.filter(\.forYou).map(\.id) == ["A"])
    }

    @Test func hidesBotPRsOnlyWhenAsked() {
        var dependabot = pr("A", details: false)
        dependabot.author = Actor(login: "dependabot", isBot: true)
        var renovate = pr("B", details: false)
        renovate.author = Actor(login: "renovate[bot]")
        let human = pr("C", details: false)
        let buckets: [Bucket: [PullRequest]] = [.team: [dependabot, renovate, human], .direct: [renovate]]

        let hidden = MenuSections(buckets: buckets, staleDays: 30, hideBots: true, now: now)
        #expect(hidden.toReview.map(\.id) == ["C"])
        #expect(hidden.badgeCount == 1)

        let shown = MenuSections(buckets: buckets, staleDays: 30, hideBots: false, now: now)
        #expect(shown.badgeCount == 3)
    }

    @Test func groupsByRepoNewestRepoFirst() {
        func item(_ id: String, _ repo: String) -> PRItem {
            var p = pr(id)
            p.repo = repo
            return PRItem(pr: p, forYou: id == "C")
        }
        let groups = [item("A", "o/b"), item("B", "o/a"), item("C", "o/b"), item("D", "x/a")].groupedByRepo()
        #expect(groups.map(\.repo) == ["o/b", "o/a", "x/a"])
        #expect(groups.map { $0.items.map(\.id) } == [["A", "C"], ["B"], ["D"]])
        #expect(groups.map(\.hasForYou) == [true, false, false])
        #expect(groups.map(\.repoName) == ["b", "a", "a"])
        #expect([PRItem]().groupedByRepo().isEmpty)
    }

    @Test func matchesNumberTitleRepoAuthorAndReviewers() {
        var p = pr("A", number: 1242, author: "dana", teams: ["platform"],
                   reviews: [Review(id: "R1", state: "COMMENTED", author: Actor(login: "bob"))])
        p.title = "fix: Leave no trace"
        p.repo = "acme/billing"
        p.requestedUsers = ["carol"]

        for query in ["", "  ", "#1242", "124", "LEAVE trace", "acme/", "billing", "dan", "@platform", "platform", "carol", "bob", "billing #1242"] {
            #expect(p.matches(query), "\(query)")
        }
        for query in ["#1243", "payments", "alice", "billing payments", "trace#1242"] {
            #expect(!p.matches(query), "\(query)")
        }
    }

    @Test func filteredKeepsMatchesInEveryList() {
        let sections = MenuSections(
            buckets: [.direct: [pr("A", number: 1)], .team: [pr("B", number: 2)], .mine: [pr("C", number: 3)], .reviewed: [pr("D", number: 4)]],
            staleDays: 30, hideBots: true, now: now
        )
        #expect(sections.filtered("title").toReview.count == 2)
        let b = sections.filtered("title b")
        #expect(b.toReview.map(\.id) == ["B"])
        #expect(b.mine.isEmpty && b.reviewed.isEmpty)
        #expect(sections.filtered("#3").mine.map(\.id) == ["C"])
    }

    @Test func age() {
        let ages = [0, 59, 60, 3_599, 3_600, 86_399, 86_400, 13 * 86_400, 14 * 86_400, 60 * 86_400].map {
            pr("A", updated: now.addingTimeInterval(-Double($0))).age(now: now)
        }
        #expect(ages == ["now", "now", "1m", "59m", "1h", "23h", "1d", "13d", "2w", "8w"])
        #expect(pr("A", updated: now.addingTimeInterval(60)).age(now: now) == "now")
    }
}
