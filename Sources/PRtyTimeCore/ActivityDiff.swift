import Foundation

public enum NotificationCategory: String, CaseIterable, Sendable {
    /// Reviews and comments on PRs you authored.
    case myPRs
    /// A PR newly requests review from you or one of your teams.
    case reviewRequests
    /// Comments, reviews and pushes on PRs you review.
    case reviewing
    /// PRs you authored or review getting merged.
    case merged
}

/// What the previous poll saw. Persisted between launches.
public struct Snapshot: Codable, Sendable, Equatable {
    public struct PRState: Codable, Sendable, Equatable {
        public var seenEventIDs: Set<String>
        public var commitOids: [String]
        /// Auto-merge was enabled. Optional so older state files still decode.
        public var autoMerge: Bool?

        public init(seenEventIDs: Set<String> = [], commitOids: [String] = [], autoMerge: Bool? = nil) {
            self.seenEventIDs = seenEventIDs
            self.commitOids = commitOids
            self.autoMerge = autoMerge
        }
    }

    /// Keyed by PR node id; only PRs fetched with details.
    public var prs: [String: PRState]
    public var directRequests: Set<String>
    public var teamRequests: Set<String>
    public var unread: Set<String>
    /// For each unread PR, the earliest its newest activity can have happened
    /// (the poll before the one that found it). Reading it on GitHub after that clears it.
    public var unreadSince: [String: Date]
    /// Unread PRs whose GitHub notification was seen unread; once it's read there, so are they.
    public var unreadOnGitHub: Set<String>
    public var polledAt: Date?

    public init(prs: [String: PRState] = [:], directRequests: Set<String> = [], teamRequests: Set<String> = [], unread: Set<String> = [],
                unreadSince: [String: Date] = [:], unreadOnGitHub: Set<String> = [], polledAt: Date? = nil) {
        self.prs = prs
        self.directRequests = directRequests
        self.teamRequests = teamRequests
        self.unread = unread
        self.unreadSince = unreadSince
        self.unreadOnGitHub = unreadOnGitHub
        self.polledAt = polledAt
    }

    private enum CodingKeys: String, CodingKey {
        case prs, directRequests, teamRequests, unread, unreadSince, unreadOnGitHub, polledAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prs = try c.decode([String: PRState].self, forKey: .prs)
        directRequests = try c.decode(Set<String>.self, forKey: .directRequests)
        teamRequests = try c.decode(Set<String>.self, forKey: .teamRequests)
        unread = try c.decode(Set<String>.self, forKey: .unread)
        // Added later, so older state files don't have them.
        unreadSince = try c.decodeIfPresent([String: Date].self, forKey: .unreadSince) ?? [:]
        unreadOnGitHub = try c.decodeIfPresent(Set<String>.self, forKey: .unreadOnGitHub) ?? []
        polledAt = try c.decodeIfPresent(Date.self, forKey: .polledAt)
    }

    /// Detailed PRs that aren't in any list of `poll`: closed, merged, or no longer involving you.
    public func missing(from poll: PollData) -> [String] {
        let present = Set(poll.buckets.values.joined().map(\.id))
        return prs.keys.filter { !present.contains($0) }.sorted()
    }
}

public struct PRNotification: Sendable, Equatable {
    public var prID: String
    public var title: String
    public var subtitle: String
    public var body: String
    public var url: URL
}

public struct DiffSettings: Sendable {
    public var ignoreBots: Bool
    public var staleDays: Int
    /// Debug: count your own actions as activity.
    public var notifySelf: Bool
    public var enabled: Set<NotificationCategory>
    public var now: Date

    public init(ignoreBots: Bool = true, staleDays: Int = 30, notifySelf: Bool = false,
                enabled: Set<NotificationCategory> = Set(NotificationCategory.allCases), now: Date = Date()) {
        self.ignoreBots = ignoreBots
        self.staleDays = staleDays
        self.notifySelf = notifySelf
        self.enabled = enabled
        self.now = now
    }

    func isFresh(_ pr: PullRequest) -> Bool {
        pr.updatedAt >= now.addingTimeInterval(-Double(staleDays) * 86_400)
    }
}

public struct DiffResult: Sendable {
    public var notifications: [PRNotification]
    public var snapshot: Snapshot
}

public enum ActivityDiff {
    public static func run(previous: Snapshot?, poll: PollData, settings: DiffSettings) -> DiffResult {
        let detailed = Dictionary(
            [Bucket.direct, .mine, .reviewed].flatMap { poll.prs(in: $0) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let direct = poll.prs(in: .direct)
        let team = poll.prs(in: .team)

        var snapshot = Snapshot(
            prs: detailed.mapValues { pr in
                Snapshot.PRState(seenEventIDs: Set(eventIDs(pr)), commitOids: pr.commits.map(\.oid), autoMerge: pr.autoMerge ? true : nil)
            },
            directRequests: Set(direct.map(\.id)),
            teamRequests: Set(team.map(\.id)),
            polledAt: settings.now
        )
        guard let previous else { return DiffResult(notifications: [], snapshot: snapshot) }

        let tracked = Set(Bucket.allCases.flatMap { poll.prs(in: $0) }.map(\.id))
        snapshot.unread = previous.unread.intersection(tracked)
        snapshot.unreadOnGitHub = previous.unreadOnGitHub.intersection(snapshot.unread)
        // Dots from before GitHub syncing (or a state file without poll times) assume the last week.
        let lastWeek = settings.now.addingTimeInterval(-7 * 86_400)
        snapshot.unreadSince = Dictionary(uniqueKeysWithValues: snapshot.unread.map { ($0, previous.unreadSince[$0] ?? lastWeek) })
        let activitySince = previous.polledAt ?? lastWeek

        let mine = Set(poll.prs(in: .mine).map(\.id))
        var notifications: [PRNotification] = []

        let orderedPRs = Bucket.allCases.flatMap { poll.prs(in: $0) }
        var handled = Set<String>()
        for pr in orderedPRs where handled.insert(pr.id).inserted {
            // Still recorded in the snapshot above, so turning the setting off
            // later doesn't announce every bot PR as a new request.
            if settings.ignoreBots && pr.author?.isBotLike == true { continue }
            var parts: [String] = []
            var events: [Event] = []
            var category: NotificationCategory?

            if !previous.directRequests.contains(pr.id), snapshot.directRequests.contains(pr.id) {
                parts.append(previous.prs[pr.id] == nil ? "Review requested from you" : "Review re-requested from you")
                category = .reviewRequests
            } else if !previous.teamRequests.contains(pr.id), snapshot.teamRequests.contains(pr.id), settings.isFresh(pr) {
                let teams = pr.requestedTeams.isEmpty ? "your team" : pr.requestedTeams.joined(separator: ", ")
                parts.append("Review requested from \(teams)")
                category = .reviewRequests
            }
            let requestNotifies = category.map(settings.enabled.contains) ?? false
            if !requestNotifies { parts = [] }

            if let pr = detailed[pr.id], let before = previous.prs[pr.id] {
                events = newEvents(pr, before: before, viewer: poll.viewer, settings: settings, includeCommits: !mine.contains(pr.id))
                let activityCategory: NotificationCategory = mine.contains(pr.id) ? .myPRs : .reviewing
                if settings.enabled.contains(activityCategory) {
                    parts += summarize(events)
                }
            }

            if category != nil || !events.isEmpty {
                snapshot.unread.insert(pr.id)
                snapshot.unreadSince[pr.id] = activitySince
                snapshot.unreadOnGitHub.remove(pr.id)
            }
            guard !parts.isEmpty else { continue }

            let singleURL = events.count == 1 && !requestNotifies ? events[0].url : nil
            notifications.append(PRNotification(
                prID: pr.id,
                title: "\(pr.repoName) #\(pr.number)",
                subtitle: pr.title,
                body: parts.joined(separator: " · "),
                url: singleURL ?? pr.url
            ))
        }

        if settings.enabled.contains(.merged) {
            for pr in poll.closed where pr.merged {
                guard let before = previous.prs[pr.id] else { continue }
                if settings.ignoreBots && pr.author?.isBotLike == true { continue }
                // Your own merges are skipped, unless auto-merge did it for you.
                let byYou = pr.mergedBy == poll.viewer
                let auto = before.autoMerge == true
                guard !byYou || auto || settings.notifySelf else { continue }
                notifications.append(PRNotification(
                    prID: pr.id,
                    title: "\(pr.repoName) #\(pr.number)",
                    subtitle: pr.title,
                    body: byYou && auto ? "Auto-merged" : "Merged by \(pr.mergedBy ?? "someone")",
                    url: pr.url
                ))
            }
        }
        return DiffResult(notifications: notifications, snapshot: snapshot)
    }

    // MARK: - Events

    enum Kind: Equatable {
        case review(String)
        case comment
        case commit
    }

    struct Event: Equatable {
        var kind: Kind
        var author: String?
        var url: URL?
    }

    static func eventIDs(_ pr: PullRequest) -> [String] {
        pr.reviews.map(\.id) + pr.comments.map(\.id) + pr.threadComments.map(\.id)
    }

    static func newEvents(_ pr: PullRequest, before: Snapshot.PRState, viewer: String, settings: DiffSettings, includeCommits: Bool) -> [Event] {
        func counts(_ actor: Actor?) -> Bool {
            guard let actor else { return false }
            if settings.ignoreBots && actor.isBotLike { return false }
            return settings.notifySelf || actor.login != viewer
        }

        var events: [Event] = []
        for review in pr.reviews
        where !before.seenEventIDs.contains(review.id) && counts(review.author) && !["DISMISSED", "PENDING"].contains(review.state) {
            events.append(Event(kind: .review(review.state), author: review.author?.login, url: review.url))
        }
        for comment in pr.comments + pr.threadComments where !before.seenEventIDs.contains(comment.id) && counts(comment.author) {
            events.append(Event(kind: .comment, author: comment.author?.login, url: comment.url))
        }
        if includeCommits, let head = pr.headOid, let oldHead = before.commitOids.last, head != oldHead {
            let known = Set(before.commitOids)
            for commit in pr.commits where !known.contains(commit.oid) && (settings.notifySelf || commit.authorLogin != viewer) {
                events.append(Event(kind: .commit, author: commit.authorLogin, url: nil))
            }
        }
        return events
    }

    /// One phrase per author, e.g. "alice approved (2 comments)", "bob pushed 3 commits".
    static func summarize(_ events: [Event]) -> [String] {
        var authors: [String] = []
        var byAuthor: [String: [Event]] = [:]
        for event in events {
            let author = event.author ?? "someone"
            if byAuthor[author] == nil { authors.append(author) }
            byAuthor[author, default: []].append(event)
        }

        return authors.flatMap { author -> [String] in
            let events = byAuthor[author]!
            let states = Set(events.compactMap { if case .review(let s) = $0.kind { s } else { nil } })
            let comments = events.filter { $0.kind == .comment }.count
            let commits = events.filter { $0.kind == .commit }.count

            var phrases: [String] = []
            if states.contains("CHANGES_REQUESTED") || states.contains("APPROVED") {
                let verb = states.contains("CHANGES_REQUESTED") ? "requested changes" : "approved"
                phrases.append("\(author) \(verb)" + (comments > 0 ? " (\(plural(comments, "comment")))" : ""))
            } else if comments > 1 {
                phrases.append("\(author) left \(plural(comments, "comment"))")
            } else if comments == 1 || !states.isEmpty {
                phrases.append("\(author) commented")
            }
            if commits > 0 {
                phrases.append("\(author) pushed \(plural(commits, "commit"))")
            }
            return phrases
        }
    }

    static func plural(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
