import AppKit
import Observation
import os
import PrtyCore

@MainActor @Observable
final class PRStore {
    static let shared = PRStore()

    private(set) var buckets: [Bucket: [PullRequest]] = [:]
    private(set) var unread: Set<String> = []
    private(set) var lastRefresh: Date?
    private(set) var errorMessage: String?
    private(set) var warning: String?
    private(set) var isRefreshing = false

    @ObservationIgnored private var snapshot: Snapshot?
    @ObservationIgnored private let client = GitHubClient()
    @ObservationIgnored private let stateStore = StateStore()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
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
            let settings = DiffSettings(
                ignoreBots: defaults.bool(forKey: Prefs.ignoreBots),
                staleDays: defaults.integer(forKey: Prefs.staleDays),
                notifySelf: Prefs.notifySelf,
                enabled: Set(NotificationCategory.allCases.filter { defaults.bool(forKey: Prefs.notifyKey($0)) })
            )
            let diff = ActivityDiff.run(previous: snapshot, poll: data, settings: settings)
            snapshot = diff.snapshot
            unread = diff.snapshot.unread
            buckets = result.data.buckets
            lastRefresh = Date()
            errorMessage = nil
            warning = result.usedFallback
                ? "Combined request timed out; fell back to \(result.requests) requests"
                : result.warnings.first
            failures = 0
            persist()
            diff.notifications.forEach(notifier.post)

            let duration = String(format: "%.1f", Date().timeIntervalSince(started))
            log.notice("poll ok: requests=\(result.requests) closed=\(data.closed.count) cost=\(result.cost) remaining=\(result.rateLimit?.remaining ?? -1) duration=\(duration, privacy: .public)s notifications=\(diff.notifications.count)")

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

    private func persist() {
        guard let snapshot else { return }
        do {
            try stateStore.save(snapshot)
        } catch {
            log.error("saving state failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
