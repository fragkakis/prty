import Foundation

/// Which search a PR came from. Declaration order is display priority: a PR
/// matching several searches is shown only under the first one.
public enum Bucket: String, Codable, Sendable, CaseIterable {
    case direct, mine, reviewed, team
}

public enum ReviewDecision: String, Codable, Sendable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

public struct Actor: Codable, Sendable, Hashable {
    public var login: String
    public var isBot: Bool
    /// Only fetched for PR authors.
    public var avatarURL: URL?

    public init(login: String, isBot: Bool = false, avatarURL: URL? = nil) {
        self.login = login
        self.isBot = isBot
        self.avatarURL = avatarURL
    }

    /// GitHub Apps show up as `Bot`; some bots are plain accounts named `foo[bot]`.
    public var isBotLike: Bool { isBot || login.hasSuffix("[bot]") }
}

public struct Review: Codable, Sendable, Hashable {
    public var id: String
    /// APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED or PENDING.
    public var state: String
    public var url: URL?
    public var author: Actor?

    public init(id: String, state: String, url: URL? = nil, author: Actor?) {
        self.id = id
        self.state = state
        self.url = url
        self.author = author
    }
}

public struct PRComment: Codable, Sendable, Hashable {
    public var id: String
    public var url: URL?
    public var author: Actor?

    public init(id: String, url: URL? = nil, author: Actor?) {
        self.id = id
        self.url = url
        self.author = author
    }
}

public struct Commit: Codable, Sendable, Hashable {
    public var oid: String
    /// nil when the commit's author email isn't linked to a GitHub account.
    public var authorLogin: String?

    public init(oid: String, authorLogin: String?) {
        self.oid = oid
        self.authorLogin = authorLogin
    }
}

/// Lines added and removed across a PR.
public struct DiffStat: Sendable, Hashable {
    public var additions: Int
    public var deletions: Int

    public init(additions: Int, deletions: Int) {
        self.additions = additions
        self.deletions = deletions
    }
}

/// What a PR's row needs beyond the poll, fetched separately (`Queries.details`).
public struct PRDetails: Sendable, Hashable {
    public var diff: DiffStat
    /// The head branch's name.
    public var branch: String

    public init(diff: DiffStat, branch: String) {
        self.diff = diff
        self.branch = branch
    }
}

/// The combined result of a commit's checks and commit statuses.
public enum CheckState: String, Codable, Sendable {
    case passing, failing, pending

    /// From GitHub's `StatusState`.
    init?(rollup: String) {
        switch rollup {
        case "SUCCESS": self = .passing
        case "FAILURE", "ERROR": self = .failing
        case "PENDING", "EXPECTED": self = .pending
        default: return nil
        }
    }
}

/// CI and merge conflicts of a PR. Fetched separately from the poll (`Queries.mergeStatus`).
public struct MergeStatus: Sendable, Hashable {
    /// Of the head commit; nil when it has no checks.
    public var checks: CheckState?
    public var conflicting: Bool
    public var headOid: String?

    public init(checks: CheckState?, conflicting: Bool = false, headOid: String?) {
        self.checks = checks
        self.conflicting = conflicting
        self.headOid = headOid
    }
}

public struct PullRequest: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var number: Int
    public var title: String
    public var url: URL
    public var isDraft: Bool
    public var updatedAt: Date
    public var author: Actor?
    /// "owner/name"
    public var repo: String
    public var requestedTeams: [String]
    /// Logins of individually requested reviewers.
    public var requestedUsers: [String]

    // Only fetched for the mine/direct/reviewed searches (the Full fragment).
    public var hasDetails: Bool
    public var reviewDecision: ReviewDecision?
    public var reviews: [Review]
    public var comments: [PRComment]
    public var threadComments: [PRComment]
    /// Oldest first; the last one is the head commit.
    public var commits: [Commit]
    /// Auto-merge is enabled.
    public var autoMerge: Bool

    public init(
        id: String, number: Int, title: String, url: URL, isDraft: Bool = false,
        updatedAt: Date, author: Actor?, repo: String, requestedTeams: [String] = [], requestedUsers: [String] = [],
        hasDetails: Bool = false, reviewDecision: ReviewDecision? = nil,
        reviews: [Review] = [], comments: [PRComment] = [], threadComments: [PRComment] = [],
        commits: [Commit] = [], autoMerge: Bool = false
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.url = url
        self.isDraft = isDraft
        self.updatedAt = updatedAt
        self.author = author
        self.repo = repo
        self.requestedTeams = requestedTeams
        self.requestedUsers = requestedUsers
        self.hasDetails = hasDetails
        self.reviewDecision = reviewDecision
        self.reviews = reviews
        self.comments = comments
        self.threadComments = threadComments
        self.commits = commits
        self.autoMerge = autoMerge
    }

    public var repoName: String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }

    public var headOid: String? { commits.last?.oid }
}

public struct RateLimit: Sendable, Equatable {
    public var cost: Int
    public var remaining: Int
    public var resetAt: Date

    public init(cost: Int, remaining: Int, resetAt: Date) {
        self.cost = cost
        self.remaining = remaining
        self.resetAt = resetAt
    }
}

/// A previously tracked PR that is no longer open.
public struct ClosedPR: Sendable, Equatable {
    public var id: String
    public var number: Int
    public var title: String
    public var url: URL
    /// "owner/name"
    public var repo: String
    public var author: Actor?
    public var merged: Bool
    public var mergedBy: String?

    public init(id: String, number: Int, title: String, url: URL, repo: String, author: Actor?, merged: Bool, mergedBy: String?) {
        self.id = id
        self.number = number
        self.title = title
        self.url = url
        self.repo = repo
        self.author = author
        self.merged = merged
        self.mergedBy = mergedBy
    }

    public var repoName: String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }
}

/// Everything one poll fetched. Each bucket is complete (all pages).
public struct PollData: Sendable {
    public var viewer: String
    public var buckets: [Bucket: [PullRequest]]
    /// PRs from the previous snapshot that have since been closed or merged.
    public var closed: [ClosedPR]
    /// Checks and conflicts of your PRs, by PR id. Empty when they aren't
    /// fetched; nil when fetching them failed, so the last known states carry over.
    public var mergeStatus: [String: MergeStatus]?

    public init(viewer: String, buckets: [Bucket: [PullRequest]], closed: [ClosedPR] = [], mergeStatus: [String: MergeStatus]? = [:]) {
        self.viewer = viewer
        self.buckets = buckets
        self.closed = closed
        self.mergeStatus = mergeStatus
    }

    public func prs(in bucket: Bucket) -> [PullRequest] { buckets[bucket] ?? [] }
}
