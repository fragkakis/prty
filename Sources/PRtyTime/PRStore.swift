import AppKit
import Observation
import os
import PRtyTimeCore

@MainActor @Observable
final class PRStore {
    static let shared = PRStore()

    private(set) var buckets: [Bucket: [PullRequest]] = [:]
    private(set) var unread: Set<String> = []
    private(set) var lastRefresh: Date?
    private(set) var errorMessage: String?
    private(set) var warning: String?
    private(set) var isRefreshing = false
    /// Line counts of the PRs on show, by PR id.
    private(set) var diffStats: [String: DiffStat] = [:]
    /// Checks and conflicts of your PRs, by PR id. Empty unless `Prefs.showChecks` is on.
    private(set) var mergeStatus: [String: MergeStatus] = [:]

    @ObservationIgnored private var snapshot: Snapshot?
    @ObservationIgnored private let client = GitHubClient()
    @ObservationIgnored private let stateStore = StateStore()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    /// The `updatedAt` each line count was fetched at, so only changed PRs are fetched again.
    @ObservationIgnored private var diffStatsAt: [String: Date] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.fragkakis.prty", category: "poll")

    func start() {
        snapshot = stateStore.load()
        unread = snapshot?.unread ?? []
        notifier.onOpen = { [weak self] id in self?.markRead(id) }
        notifier.activate()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                // Give the network a moment to come back.
                try? await Task.sleep(for: .seconds(5))
                PRStore.shared.refreshNow()
            }
        }
        restartLoop()
    }

    func refreshNow() {
        guard !isRefreshing else { return }
        restartLoop()
    }

    func open(_ pr: PullRequest) {
        NSWorkspace.shared.open(pr.url)
        markRead(pr.id)
    }

    func markRead(_ id: String) {
        guard unread.remove(id) != nil else { return }
        snapshot?.unread = unread
        persist()
    }

    private func restartLoop() {
        loop?.cancel()
        loop = Task {
            while !Task.isCancelled {
                let delay = await poll()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Runs one poll and returns the number of seconds until the next one.
    private func poll() async -> TimeInterval {
        isRefreshing = true
        defer { isRefreshing = false }
        let defaults = UserDefaults.standard
        let interval = max(1, defaults.double(forKey: Prefs.pollMinutes)) * 60
        let started = Date()

        do {
            let result = try await client.poll()
            var data = result.data
            // PRs that left every list: look up which were merged.
            if let missing = snapshot?.missing(from: data), !missing.isEmpty {
                do {
                    data.closed = try await client.closedPRs(missing)
                } catch {
                    log.error("checking \(missing.count) closed PRs failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            // Every poll, not only for updated PRs like line counts: checks
            // finishing needn't change a PR's updatedAt.
            if defaults.bool(forKey: Prefs.showChecks) {
                let mine = data.prs(in: .mine).map(\.id)
                do {
                    data.mergeStatus = try await client.mergeStatus(mine)
                } catch {
                    data.mergeStatus = nil
                    log.error("fetching checks for \(mine.count) PRs failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            let settings = DiffSettings(
                ignoreBots: defaults.bool(forKey: Prefs.ignoreBots),
                staleDays: defaults.integer(forKey: Prefs.staleDays),
                notifySelf: Prefs.notifySelf,
                enabled: Set(NotificationCategory.allCases.filter { defaults.bool(forKey: Prefs.notifyKey($0)) })
            )
            let diff = ActivityDiff.run(previous: snapshot, poll: data, settings: settings)
            var next = diff.snapshot
            // Clear dots for PRs read on GitHub. Bounded, so a dot that never
            // clears doesn't widen the request forever.
            var readOnGitHub = 0
            if let since = next.inboxSince {
                do {
                    let inbox = try await client.inbox(since: max(since, Date().addingTimeInterval(-14 * 86_400)))
                    readOnGitHub = next.syncRead(with: inbox, prs: data.buckets.values.flatMap { $0 })
                } catch {
                    log.error("checking GitHub notifications failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            snapshot = next
            unread = next.unread
            buckets = result.data.buckets
            // On a failed fetch (nil) keep showing the last ones.
            if let fresh = data.mergeStatus, fresh != mergeStatus { mergeStatus = fresh }
            lastRefresh = Date()
            errorMessage = nil
            warning = result.usedFallback
                ? "Combined request timed out; fell back to \(result.requests) requests"
                : result.warnings.first
            failures = 0
            persist()
            diff.notifications.forEach(notifier.post)
            let shown = MenuSections(buckets: data.buckets, staleDays: settings.staleDays, hideBots: settings.ignoreBots)
            let diffsFetched = await refreshDiffStats(for: shown.toReview.map(\.pr) + shown.reviewed + shown.mine)

            let duration = String(format: "%.1f", Date().timeIntervalSince(started))
            log.notice("poll ok: requests=\(result.requests) closed=\(data.closed.count) readOnGitHub=\(readOnGitHub) cost=\(result.cost) remaining=\(result.rateLimit?.remaining ?? -1) diffs=\(diffsFetched) checks=\(data.mergeStatus?.count ?? -1) duration=\(duration, privacy: .public)s notifications=\(diff.notifications.count)")

            if let limit = result.rateLimit, limit.remaining < 200 {
                warning = "Rate limit low (\(limit.remaining) left), pausing until \(limit.resetAt.formatted(date: .omitted, time: .shortened))"
                return max(interval, limit.resetAt.timeIntervalSinceNow + 5)
            }
            return interval
        } catch {
            if Task.isCancelled { return interval }
            failures += 1
            errorMessage = error.localizedDescription
            log.error("poll failed (\(self.failures)x): \(error.localizedDescription, privacy: .public)")
            return min(30 * pow(2, Double(failures - 1)), 600)
        }
    }

    /// Fetches line counts for PRs that are new or updated since their last fetch,
    /// and drops the ones no longer shown. Returns how many were requested.
    private func refreshDiffStats(for prs: [PullRequest]) async -> Int {
        let updatedAt = Dictionary(prs.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { first, _ in first })
        diffStatsAt = diffStatsAt.filter { updatedAt[$0.key] != nil }
        let kept = diffStats.filter { updatedAt[$0.key] != nil }
        if kept.count != diffStats.count { diffStats = kept } // avoid redrawing the panel every poll
        guard UserDefaults.standard.bool(forKey: Prefs.showLineCounts) else { return 0 }
        let stale = updatedAt.filter { diffStatsAt[$0.key] != $0.value }.map(\.key)
        guard !stale.isEmpty else { return 0 }
        do {
            diffStats.merge(try await client.diffStats(stale)) { $1 }
            for id in stale { diffStatsAt[id] = updatedAt[id] }
        } catch {
            log.error("fetching line counts for \(stale.count) PRs failed: \(error.localizedDescription, privacy: .public)")
        }
        return stale.count
    }

    private func persist() {
        guard let snapshot else { return }
        do {
            try stateStore.save(snapshot)
        } catch {
            log.error("saving state failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
