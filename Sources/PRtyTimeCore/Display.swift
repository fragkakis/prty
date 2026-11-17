import Foundation

/// A PR as listed in the panel.
public struct PRItem: Sendable, Identifiable {
    public var pr: PullRequest
    /// Review requested from you directly, rather than via one of your teams.
    public var forYou: Bool
    public var id: String { pr.id }

    public init(pr: PullRequest, forYou: Bool = false) {
        self.pr = pr
        self.forYou = forYou
    }
}

public struct RepoGroup: Sendable, Identifiable {
    /// "owner/name"
    public var repo: String
    public var items: [PRItem]
    public var id: String { repo }

    public var repoName: String { items.first?.pr.repoName ?? repo }
    public var hasForYou: Bool { items.contains(where: \.forYou) }
}

extension Array where Element == PRItem {
    /// Groups by repo, keeping order: a repo is placed where its first item is.
    public func groupedByRepo() -> [RepoGroup] {
        var groups: [RepoGroup] = []
        var index: [String: Int] = [:]
        for item in self {
            if let i = index[item.pr.repo] {
                groups[i].items.append(item)
            } else {
                index[item.pr.repo] = groups.count
                groups.append(RepoGroup(repo: item.pr.repo, items: [item]))
            }
        }
        return groups
    }
}

public struct MenuSections: Sendable {
    /// Direct and fresh team requests together, most recently updated first.
    public var toReview: [PRItem] = []
    /// PRs you reviewed that nobody is currently asking you to review again.
    public var reviewed: [PullRequest] = []
    public var mine: [PullRequest] = []

    /// Shown next to the menu-bar icon.
    public var badgeCount: Int { toReview.count }

    /// Only the PRs matching `query` (see `PullRequest.matches`).
    public func filtered(_ query: String) -> MenuSections {
        var copy = self
        copy.toReview = toReview.filter { $0.pr.matches(query) }
        copy.reviewed = reviewed.filter { $0.matches(query) }
        copy.mine = mine.filter { $0.matches(query) }
        return copy
    }

    public init(buckets: [Bucket: [PullRequest]], staleDays: Int, hideBots: Bool, now: Date = Date()) {
        var seen = Set<String>()
        func take(_ bucket: Bucket) -> [PullRequest] {
            (buckets[bucket] ?? [])
                .filter { !(hideBots && $0.author?.isBotLike == true) && seen.insert($0.id).inserted }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
        let direct = take(.direct)
        mine = take(.mine)
        reviewed = take(.reviewed)

        let cutoff = now.addingTimeInterval(-Double(staleDays) * 86_400)
        let team = take(.team).filter { $0.updatedAt >= cutoff }
        toReview = (direct.map { PRItem(pr: $0, forYou: true) } + team.map { PRItem(pr: $0) })
            .sorted { $0.pr.updatedAt > $1.pr.updatedAt }
    }
}

extension PullRequest {
    /// Whether every whitespace-separated term of `query` appears, ignoring
    /// case, in the number ("#123"), title, repo, author or reviewers
    /// (requested people, requested teams as "@team", and past reviewers).
    public func matches(_ query: String) -> Bool {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        if terms.isEmpty { return true }
        let reviewers = requestedUsers + requestedTeams.map { "@" + $0 } + reviews.compactMap { $0.author?.login }
        // Space-separated, and terms never contain spaces, so a term can't span two fields.
        let text = (["#\(number)", title, repo, author?.login ?? ""] + reviewers).joined(separator: " ").lowercased()
        return terms.allSatisfy { text.contains($0) }
    }

    /// Time since the last update: "now", "5m", "3h", "4d", "6w".
    public func age(now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(updatedAt))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<(14 * 86_400): return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / (7 * 86_400)))w"
        }
    }
}

extension DiffStat {
    /// "+12" and "−3", compacted past 999 ("+1.2k"); nil for an empty diff.
    public var labels: (added: String, removed: String)? {
        guard additions + deletions > 0 else { return nil }
        return ("+" + Self.compact(additions), "−" + Self.compact(deletions))
    }

    /// 950, 1.2k, 12k.
    static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000:
            return "\(n)"
        case ..<9_950:
            let tenths = (n + 50) / 100
            return tenths % 10 == 0 ? "\(tenths / 10)k" : "\(tenths / 10).\(tenths % 10)k"
        default:
            return "\((n + 500) / 1_000)k"
        }
    }
}
