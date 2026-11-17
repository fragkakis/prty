import Foundation

/// Decoded body of one combined poll request.
struct PollResponse: Decodable, Sendable {
    struct GraphQLError: Decodable, Sendable {
        var message: String
        var type: String?
    }

    struct Data: Decodable, Sendable {
        var viewer: String
        var searches: [Bucket: Search]
        var rateLimit: RateLimit?

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ s: String) { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        private struct Viewer: Decodable, Sendable { var login: String }
        private struct RawRateLimit: Decodable, Sendable { var cost: Int; var remaining: Int; var resetAt: Date }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            viewer = try c.decode(Viewer.self, forKey: Key("viewer")).login
            var searches: [Bucket: Search] = [:]
            for bucket in Bucket.allCases {
                if let s = try c.decodeIfPresent(Search.self, forKey: Key(bucket.rawValue)) {
                    searches[bucket] = s
                }
            }
            self.searches = searches
            rateLimit = try c.decodeIfPresent(RawRateLimit.self, forKey: Key("rateLimit"))
                .map { RateLimit(cost: $0.cost, remaining: $0.remaining, resetAt: $0.resetAt) }
        }
    }

    struct Search: Decodable, Sendable {
        struct PageInfo: Decodable, Sendable { var hasNextPage: Bool; var endCursor: String? }
        var issueCount: Int
        var pageInfo: PageInfo
        var nodes: [RawPR]
    }

    var data: Data?
    var errors: [GraphQLError]?

    static func decode(_ body: Foundation.Data) throws -> PollResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PollResponse.self, from: body)
    }
}

private struct Nodes<T: Decodable & Sendable>: Decodable, Sendable { var nodes: [T] }

private struct RawActor: Decodable, Sendable {
    var typename: String
    var login: String
    var avatarUrl: URL?
    enum CodingKeys: String, CodingKey { case typename = "__typename", login, avatarUrl }

    var actor: Actor { Actor(login: login, isBot: typename == "Bot", avatarURL: avatarUrl) }
}

struct RawPR: Decodable, Sendable {
    private struct Repo: Decodable, Sendable { var nameWithOwner: String }
    private struct ReviewRequest: Decodable, Sendable {
        struct Reviewer: Decodable, Sendable { var slug: String?; var login: String? }
        var requestedReviewer: Reviewer?
    }
    private struct AutoMergeRequest: Decodable, Sendable { var enabledAt: Date? }
    private struct RawReview: Decodable, Sendable { var id: String; var state: String; var url: URL?; var author: RawActor? }
    private struct RawComment: Decodable, Sendable { var id: String; var url: URL?; var author: RawActor? }
    private struct Thread: Decodable, Sendable { var comments: Nodes<RawComment> }
    private struct CommitNode: Decodable, Sendable {
        struct Inner: Decodable, Sendable {
            struct Author: Decodable, Sendable { struct User: Decodable, Sendable { var login: String }; var user: User? }
            var oid: String
            var author: Author?
        }
        var commit: Inner
    }

    private var id: String
    private var number: Int
    private var title: String
    private var url: URL
    private var isDraft: Bool
    private var updatedAt: Date
    private var author: RawActor?
    private var repository: Repo
    private var reviewRequests: Nodes<ReviewRequest>?
    private var reviewDecision: String?
    private var autoMergeRequest: AutoMergeRequest?
    private var reviews: Nodes<RawReview>?
    private var comments: Nodes<RawComment>?
    private var reviewThreads: Nodes<Thread>?
    private var commits: Nodes<CommitNode>?

    var pullRequest: PullRequest {
        let comment = { (c: RawComment) in PRComment(id: c.id, url: c.url, author: c.author?.actor) }
        return PullRequest(
            id: id, number: number, title: title, url: url, isDraft: isDraft, updatedAt: updatedAt,
            author: author?.actor, repo: repository.nameWithOwner,
            requestedTeams: reviewRequests?.nodes.compactMap { $0.requestedReviewer?.slug } ?? [],
            requestedUsers: reviewRequests?.nodes.compactMap { $0.requestedReviewer?.login } ?? [],
            hasDetails: reviews != nil,
            reviewDecision: reviewDecision.flatMap(ReviewDecision.init(rawValue:)),
            reviews: reviews?.nodes.map { Review(id: $0.id, state: $0.state, url: $0.url, author: $0.author?.actor) } ?? [],
            comments: comments?.nodes.map(comment) ?? [],
            threadComments: reviewThreads?.nodes.flatMap { $0.comments.nodes.map(comment) } ?? [],
            commits: commits?.nodes.map { Commit(oid: $0.commit.oid, authorLogin: $0.commit.author?.user?.login) } ?? [],
            autoMerge: autoMergeRequest != nil
        )
    }
}

/// Decoded body of a `Queries.states` request.
struct StatesResponse: Decodable, Sendable {
    struct Node: Decodable, Sendable {
        private struct Repo: Decodable, Sendable { var nameWithOwner: String }
        private struct User: Decodable, Sendable { var login: String }

        var id: String
        private var number: Int
        private var title: String
        private var url: URL
        /// OPEN, CLOSED or MERGED.
        var state: String
        private var mergedBy: User?
        private var author: RawActor?
        private var repository: Repo

        var closedPR: ClosedPR {
            ClosedPR(
                id: id, number: number, title: title, url: url, repo: repository.nameWithOwner,
                author: author?.actor, merged: state == "MERGED", mergedBy: mergedBy?.login
            )
        }
    }

    struct Data: Decodable, Sendable {
        /// null for ids that no longer resolve (e.g. a deleted repo).
        var nodes: [Node?]
    }

    var data: Data?
    var errors: [PollResponse.GraphQLError]?

    static func decode(_ body: Foundation.Data) throws -> StatesResponse {
        try JSONDecoder().decode(StatesResponse.self, from: body)
    }

    /// PRs that are no longer open.
    var closed: [ClosedPR] {
        (data?.nodes ?? []).compactMap { $0 }.filter { $0.state != "OPEN" }.map(\.closedPR)
    }
}
