import AppKit
import PRtyTimeCore
import SwiftUI

struct MenuBarLabel: View {
    let store: PRStore
    @AppStorage(Prefs.staleDays) private var staleDays = 30
    @AppStorage(Prefs.ignoreBots) private var ignoreBots = true

    var body: some View {
        let count = MenuSections(buckets: store.buckets, staleDays: staleDays, hideBots: ignoreBots).badgeCount
        HStack(spacing: 2) {
            if store.errorMessage == nil {
                Image(nsImage: MenuBarIcon.image).renderingMode(.template)
            } else {
                Image(systemName: "exclamationmark.triangle")
            }
            if count > 0 { Text("\(count)") }
        }
    }
}

enum PanelTab: Hashable {
    case review, mine
}

/// The panel's view state. With only the Command Line Tools, `@State` doesn't
/// compile (it is a macro in the macOS 27 SDK and its plugin ships with Xcode),
/// so view-local state lives here. There is only one panel.
@MainActor @Observable
final class PanelState {
    static let shared = PanelState()
    private static let collapsedKey = "collapsedGroups"

    var tab = PanelTab.review
    var query = ""
    var hoveredID: String?
    var listHeights: [PanelTab: CGFloat] = [:]
    /// Collapsed repo groups as "<section>/<owner>/<repo>", kept across launches.
    var collapsed = Set(UserDefaults.standard.stringArray(forKey: PanelState.collapsedKey) ?? []) {
        didSet { UserDefaults.standard.set(collapsed.sorted(), forKey: Self.collapsedKey) }
    }
}

/// The panel shown when clicking the menu-bar icon.
struct MenuContent: View {
    let store: PRStore
    @AppStorage(Prefs.staleDays) private var staleDays = 30
    @AppStorage(Prefs.ignoreBots) private var ignoreBots = true
    @AppStorage(Prefs.showLineCounts) private var showLineCounts = true
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    private let panel = PanelState.shared

    var body: some View {
        let all = MenuSections(buckets: store.buckets, staleDays: staleDays, hideBots: ignoreBots)
        let shown = filtering ? all.filtered(panel.query) : all

        VStack(spacing: 0) {
            filterField
                .padding([.horizontal, .top], 10)
            Picker("", selection: Binding(get: { panel.tab }, set: { panel.tab = $0 })) {
                Text("To review (\(shown.toReview.count))").tag(PanelTab.review)
                Text("My PRs (\(shown.mine.count))").tag(PanelTab.mine)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            if let error = store.errorMessage { banner(error) }
            if let warning = store.warning { banner(warning) }

            Divider()
            // Both tabs share the taller tab's unfiltered, fully expanded height
            // (capped; scrolls beyond), so switching tabs, collapsing groups or
            // filtering never resizes the panel. MenuBarExtra resizes around the
            // center, which would move it away from the menu bar.
            // While filtering, every group is expanded so no match is hidden.
            ScrollView { list(panel.tab, shown, expandAll: filtering) }
                .frame(height: min(max(panel.listHeights.values.max() ?? 0, 1), 520))
                .background {
                    VStack {
                        measured(.review, all)
                        measured(.mine, all)
                    }
                    .hidden()
                }
            Divider()
            footer
        }
        .frame(width: 460)
        .pinTopOnResize()
    }

    private var filtering: Bool { !panel.query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by #, title, repo, author, reviewer", text: Binding(get: { panel.query }, set: { panel.query = $0 }))
                .textFieldStyle(.plain)
                .onKeyPress(.escape) {
                    // Esc clears the filter; with nothing to clear, let it close the panel.
                    guard !panel.query.isEmpty else { return .ignored }
                    panel.query = ""
                    return .handled
                }
            if !panel.query.isEmpty {
                Button { panel.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }

    private func list(_ tab: PanelTab, _ sections: MenuSections, expandAll: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            switch tab {
            case .review: reviewTab(sections, expandAll: expandAll)
            case .mine: mineTab(sections, expandAll: expandAll)
            }
        }
        .padding(6)
    }

    /// The tab's list, fully expanded, at its natural height, reporting that height.
    private func measured(_ tab: PanelTab, _ sections: MenuSections) -> some View {
        list(tab, sections, expandAll: true)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panel.listHeights[tab] = $0 }
            .frame(height: 0, alignment: .top)
    }

    @ViewBuilder private func reviewTab(_ sections: MenuSections, expandAll: Bool) -> some View {
        if sections.toReview.isEmpty && sections.reviewed.isEmpty {
            empty(filtering ? "No matching PRs" : "Nothing to review")
        }
        groups(sections.toReview, section: "review", expandAll: expandAll)
        if !sections.reviewed.isEmpty {
            header("Reviewed by you")
            groups(sections.reviewed.map { PRItem(pr: $0) }, section: "reviewed", expandAll: expandAll)
        }
    }

    @ViewBuilder private func mineTab(_ sections: MenuSections, expandAll: Bool) -> some View {
        if sections.mine.isEmpty { empty(filtering ? "No matching PRs" : "No open PRs") }
        groups(sections.mine.map { PRItem(pr: $0) }, section: "mine", mine: true, expandAll: expandAll)
    }

    /// Collapsible per-repo groups. `section` keeps collapse state separate per list.
    private func groups(_ items: [PRItem], section: String, mine: Bool = false, expandAll: Bool) -> some View {
        ForEach(items.groupedByRepo()) { group in
            let key = "\(section)/\(group.repo)"
            let collapsed = !expandAll && panel.collapsed.contains(key)
            GroupHeader(group: group, key: key, collapsed: collapsed, collapsible: !expandAll, hasUnread: group.items.contains { isUnread($0.pr) })
            if !collapsed {
                ForEach(group.items) { item in
                    PRRow(pr: item.pr, unread: isUnread(item.pr), forYou: item.forYou, showAuthor: !mine, labeledStatus: mine, diff: showLineCounts ? store.diffStats[item.pr.id] : nil) {
                        open(item.pr)
                    }
                    .padding(.leading, 16)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button { store.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                .keyboardShortcut("r")
                .help("Refresh now (⌘R)")
                .disabled(store.isRefreshing)
            Button {
                dismiss()
                NSApp.activate()
                openSettings()
            } label: { Image(systemName: "gearshape") }
                .keyboardShortcut(",")
                .help("Settings (⌘,)")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .keyboardShortcut("q")
                .help("Quit PRty Time (⌘Q)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var status: String {
        guard let lastRefresh = store.lastRefresh else { return "Loading…" }
        let time = lastRefresh.formatted(date: .omitted, time: .shortened)
        return "Updated at \(time)" + (store.isRefreshing ? " · refreshing…" : "")
    }

    private func isUnread(_ pr: PullRequest) -> Bool { store.unread.contains(pr.id) }

    private func open(_ pr: PullRequest) {
        store.open(pr)
        dismiss()
    }

    private func banner(_ text: String) -> some View {
        Text("⚠️ \(text)")
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func empty(_ text: String) -> some View {
        Text(store.lastRefresh == nil ? "Loading…" : text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }
}

private struct GroupHeader: View {
    let group: RepoGroup
    let key: String
    let collapsed: Bool
    /// Off while filtering, when every group is shown expanded.
    let collapsible: Bool
    let hasUnread: Bool
    private let panel = PanelState.shared

    private var hovering: Bool { panel.hoveredID == key }

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) {
                if collapsed { panel.collapsed.remove(key) } else { panel.collapsed.insert(key) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 10)
                Text(group.repoName)
                    .font(.callout.weight(.semibold))
                Text("\(group.items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // What the collapsed rows would have shown.
                if collapsed && hasUnread {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                }
                if collapsed && group.hasForYou { YouBadge() }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(collapsible)
        .padding(.top, 4)
        .onHover { inside in
            if inside {
                panel.hoveredID = key
            } else if hovering {
                panel.hoveredID = nil
            }
        }
        .help(group.repo)
    }
}

private struct YouBadge: View {
    var body: some View {
        Text("You")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor, in: Capsule())
    }
}

private struct PRRow: View {
    let pr: PullRequest
    let unread: Bool
    var forYou = false
    var showAuthor = true
    /// Spell out the review decision instead of showing just an icon.
    var labeledStatus = false
    var diff: DiffStat?
    let action: () -> Void
    private let panel = PanelState.shared

    private var hovering: Bool { panel.hoveredID == pr.id }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(unread ? Color.accentColor : .clear)
                    .frame(width: 6, height: 6)
                if showAuthor {
                    Avatar(url: pr.author?.avatarURL)
                        .padding(.trailing, 2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(pr.title)
                        .fontWeight(forYou ? .semibold : .regular)
                        .foregroundStyle(pr.isDraft ? .secondary : .primary)
                        .lineLimit(1)
                    subtitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if forYou { YouBadge() }
                if pr.isDraft { tag("Draft") }
                decision
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(background, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                panel.hoveredID = pr.id
            } else if hovering {
                panel.hoveredID = nil
            }
        }
        .help(pr.title)
    }

    /// "#12 · +40 −3 · author · @teams · 2h". The diff comes early so a long team list can't truncate it.
    private var subtitle: Text {
        // verbatim: an interpolated Int in a localized Text gets a thousands separator ("#1.570").
        var text = Text(verbatim: "#\(pr.number)")
        if let labels = diff?.labels {
            text = text + Text(" · ") + Text(labels.added).foregroundStyle(Color.linesAdded) + Text(" ") + Text(labels.removed).foregroundStyle(Color.linesRemoved)
        }
        var rest: [String] = []
        if showAuthor, let author = pr.author { rest.append(author.login) }
        if !forYou, !pr.requestedTeams.isEmpty { rest.append("@" + pr.requestedTeams.joined(separator: ", @")) }
        rest.append(pr.age())
        return text + Text(" · " + rest.joined(separator: " · "))
    }

    private var background: Color {
        if hovering { return .primary.opacity(0.1) }
        return forYou ? .accentColor.opacity(0.12) : .clear
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(.secondary.opacity(0.5)))
    }

    @ViewBuilder private var decision: some View {
        switch pr.reviewDecision {
        case .approved: status("Approved", "checkmark.circle.fill", .green)
        case .changesRequested: status("Changes requested", "xmark.circle.fill", .red)
        case .reviewRequired where labeledStatus: status("Awaiting review", "clock", .secondary)
        default: EmptyView()
        }
    }

    @ViewBuilder private func status(_ text: String, _ icon: String, _ color: some ShapeStyle) -> some View {
        if labeledStatus {
            Label(text, systemImage: icon).font(.caption).foregroundStyle(color)
        } else {
            Image(systemName: icon).foregroundStyle(color).help(text)
        }
    }
}

private extension Color {
    // GitHub's diff colors. The system green and red are too light to read on white.
    static let linesAdded = adaptive(light: (0x1A, 0x7F, 0x37), dark: (0x3F, 0xB9, 0x50))
    static let linesRemoved = adaptive(light: (0xCF, 0x22, 0x2E), dark: (0xF8, 0x51, 0x49))

    static func adaptive(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        })
    }
}

extension View {
    /// Keep the top edge in place if the panel resizes while open (e.g. a poll
    /// adds PRs). Without it MenuBarExtra resizes around the center.
    @ViewBuilder func pinTopOnResize() -> some View {
        if #available(macOS 26, *) {
            windowResizeAnchor(.top)
        } else {
            self
        }
    }
}
