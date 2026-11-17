import Foundation

public struct SearchSpec: Sendable, Hashable {
    public var bucket: Bucket
    public var query: String
    public var pageSize: Int
    /// Full fragment (reviews, comments, commits) vs Lite (list fields only).
    /// `reviewDecision` alone takes the team search from ~2s to ~9.5s, so the
    /// big team list stays Lite to keep the request under GitHub's 10s cutoff.
    public var full: Bool

    public var searchString: String { "is:pr is:open archived:false \(query)" }
}

public struct SearchPage: Sendable, Hashable {
    public var spec: SearchSpec
    public var after: String?

    public init(spec: SearchSpec, after: String? = nil) {
        self.spec = spec
        self.after = after
    }
}

public enum Queries {
    public static let specs: [SearchSpec] = [
        SearchSpec(bucket: .mine, query: "author:@me", pageSize: 25, full: true),
        SearchSpec(bucket: .direct, query: "user-review-requested:@me", pageSize: 25, full: true),
        SearchSpec(bucket: .reviewed, query: "reviewed-by:@me -author:@me", pageSize: 25, full: true),
        SearchSpec(bucket: .team, query: "review-requested:@me -user-review-requested:@me", pageSize: 100, full: false),
    ]

    static let liteFragment = """
        fragment Lite on PullRequest {
          id number title url isDraft updatedAt
          author { __typename login avatarUrl(size: 64) }
          repository { nameWithOwner }
          reviewRequests(first: 10) { nodes { requestedReviewer { __typename ... on Team { slug } ... on User { login } } } }
        }
        """

    static let fullFragment = """
        fragment Full on PullRequest {
          ...Lite
          reviewDecision
          autoMergeRequest { enabledAt }
          reviews(last: 20) { nodes { id state url author { __typename login } } }
          comments(last: 20) { nodes { id url author { __typename login } } }
          reviewThreads(last: 20) { nodes { comments(last: 5) { nodes { id url author { __typename login } } } } }
          commits(last: 5) { nodes { commit { oid author { user { login } } } } }
        }
        """

    /// One request containing every page, each aliased by its bucket name.
    /// GraphQL rejects unused fragments, so Full is only included when needed.
    public static func build(_ pages: [SearchPage]) -> String {
        let needsFull = pages.contains { $0.spec.full }
        var searches: [String] = []
        for page in pages {
            let spec = page.spec
            var args = "query: \(literal(spec.searchString)), type: ISSUE, first: \(spec.pageSize)"
            if let after = page.after { args += ", after: \(literal(after))" }
            searches.append(
                "  \(spec.bucket.rawValue): search(\(args)) { issueCount pageInfo { hasNextPage endCursor } nodes { ...\(spec.full ? "Full" : "Lite") } }"
            )
        }
        return ([liteFragment] + (needsFull ? [fullFragment] : []) + [
            "query {\n  viewer { login }\n\(searches.joined(separator: "\n"))\n  rateLimit { cost remaining resetAt }\n}",
        ]).joined(separator: "\n")
    }

    /// Current state of PRs by node id, to tell merged from closed.
    public static func states(_ ids: [String]) -> String {
        let list = ids.map(literal).joined(separator: ", ")
        return """
            query {
              nodes(ids: [\(list)]) {
                ... on PullRequest { id number title url state mergedBy { login } author { __typename login } repository { nameWithOwner } }
              }
            }
            """
    }

    static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
