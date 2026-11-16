import Foundation

public enum GitHubError: Error, LocalizedError, Equatable {
    case auth(String)
    case timeout
    case http(Int, String)
    case graphQL([String])
    case incomplete(String)

    public var errorDescription: String? {
        switch self {
        case .auth(let message): message
        case .timeout: "GitHub timed out"
        case .http(let status, let body): "GitHub returned HTTP \(status): \(body)"
        case .graphQL(let messages): "GitHub error: \(messages.joined(separator: "; "))"
        case .incomplete(let message): message
        }
    }
}

public struct PollResult: Sendable {
    public var data: PollData
    public var rateLimit: RateLimit?
    public var requests: Int
    public var cost: Int
    public var usedFallback: Bool
    /// GraphQL errors that came back alongside usable data.
    public var warnings: [String]
}

/// Reads the token the `gh` CLI is logged in with.
public enum GHToken {
    static let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    public static func read() throws -> String {
        guard let gh = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw GitHubError.auth("gh not found. Install it with `brew install gh`, then run `gh auth login`.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["auth", "token", "--hostname", "github.com"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let token = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !token.isEmpty else {
            throw GitHubError.auth("`gh auth token` failed. Run `gh auth login`.")
        }
        return token
    }
}

public actor GitHubClient {
    /// The GraphQL API (v4) isn't versioned. Send this as `X-GitHub-Api-Version`
    /// on any REST call; without it GitHub serves 2022-11-28.
    public static let restAPIVersion = "2026-03-10"
    static let endpoint = URL(string: "https://api.github.com/graphql")!
    static let maxRounds = 10

    private let session: URLSession
    private let tokenProvider: @Sendable () throws -> String
    private var token: String?

    public init(session: URLSession = .shared, tokenProvider: @escaping @Sendable () throws -> String = GHToken.read) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    /// Fetches every bucket in one request. Further requests only go out for
    /// buckets with more results than their page size, or when the combined
    /// request times out (then each search is sent on its own, in parallel).
    public func poll() async throws -> PollResult {
        var buckets: [Bucket: [PullRequest]] = [:]
        var pending = Queries.specs.map { SearchPage(spec: $0) }
        var viewer = ""
        var rateLimit: RateLimit?
        var requests = 0, cost = 0
        var usedFallback = false
        var warnings: [String] = []

        for _ in 0..<Self.maxRounds {
            let responses: [(PollResponse.Data, [String])]
            do {
                responses = [try await send(pending)]
                requests += 1
            } catch GitHubError.timeout where pending.count > 1 {
                usedFallback = true
                requests += pending.count
                responses = try await withThrowingTaskGroup(of: (PollResponse.Data, [String]).self) { group in
                    for page in pending {
                        group.addTask { try await self.send([page]) }
                    }
                    var collected: [(PollResponse.Data, [String])] = []
                    for try await response in group { collected.append(response) }
                    return collected
                }
            }

            var next: [SearchPage] = []
            for (data, messages) in responses {
                viewer = data.viewer
                warnings += messages
                if let limit = data.rateLimit {
                    cost += limit.cost
                    if rateLimit == nil || limit.remaining < rateLimit!.remaining { rateLimit = limit }
                }
                for (bucket, search) in data.searches {
                    buckets[bucket, default: []] += search.nodes.map(\.pullRequest)
                    if search.pageInfo.hasNextPage, let cursor = search.pageInfo.endCursor,
                       let spec = pending.first(where: { $0.spec.bucket == bucket })?.spec {
                        next.append(SearchPage(spec: spec, after: cursor))
                    }
                }
            }
            if next.isEmpty {
                for bucket in Bucket.allCases where buckets[bucket] == nil { buckets[bucket] = [] }
                return PollResult(
                    data: PollData(viewer: viewer, buckets: buckets), rateLimit: rateLimit,
                    requests: requests, cost: cost, usedFallback: usedFallback, warnings: warnings
                )
            }
            pending = next
        }
        throw GitHubError.incomplete("Gave up paging after \(Self.maxRounds) requests")
    }

    private func currentToken() throws -> String {
        if let token { return token }
        let fresh = try tokenProvider()
        token = fresh
        return fresh
    }

    /// Which of these PRs (by node id) are no longer open. One request, ~1 point.
    public func closedPRs(_ ids: [String]) async throws -> [ClosedPR] {
        guard !ids.isEmpty else { return [] }
        var closed: [ClosedPR] = []
        // nodes(ids:) takes at most 100.
        for start in stride(from: 0, to: ids.count, by: 100) {
            let body = try await post(Queries.states(Array(ids[start..<min(start + 100, ids.count)])))
            let decoded = try StatesResponse.decode(body)
            guard decoded.data != nil else { throw GitHubError.graphQL(decoded.errors?.map(\.message) ?? []) }
            closed += decoded.closed
        }
        return closed
    }

    private func send(_ pages: [SearchPage]) async throws -> (PollResponse.Data, [String]) {
        let decoded = try PollResponse.decode(try await post(Queries.build(pages)))
        let messages = decoded.errors?.map(\.message) ?? []
        guard let data = decoded.data else {
            if messages.contains(where: { $0.localizedCaseInsensitiveContains("timeout") }) { throw GitHubError.timeout }
            throw GitHubError.graphQL(messages)
        }
        // A search that errored comes back null. Treating it as empty would make
        // its PRs look removed and then newly added on the next poll.
        guard pages.allSatisfy({ data.searches[$0.spec.bucket] != nil }) else {
            throw GitHubError.graphQL(messages.isEmpty ? ["a search returned no data"] : messages)
        }
        return (data, messages)
    }

    /// Sends a GraphQL query and returns the body of a 200 response.
    private func post(_ query: String, retryAuth: Bool = true) async throws -> Data {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("bearer \(try currentToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Prty", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

        let body: Data, response: URLResponse
        do {
            (body, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw GitHubError.timeout
        }

        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            return body
        case 401:
            token = nil
            if retryAuth { return try await post(query, retryAuth: false) }
            throw GitHubError.auth("GitHub rejected the gh token (401). Run `gh auth login`.")
        case 502, 504:
            throw GitHubError.timeout
        case let status:
            throw GitHubError.http(status, String(decoding: body.prefix(200), as: UTF8.self))
        }
    }
}
