import Observation
import PRtyTimeCore
import ServiceManagement
import SwiftUI

// No @State here: in the macOS 27 SDK it's a macro whose plugin only ships with
// Xcode, so it doesn't build with the Command Line Tools alone.
struct SettingsView: View {
    @AppStorage(Prefs.pollMinutes) private var pollMinutes = 2.0
    @AppStorage(Prefs.staleDays) private var staleDays = 30
    @AppStorage(Prefs.ignoreBots) private var ignoreBots = true
    @AppStorage(Prefs.showLineCounts) private var showLineCounts = true
    @AppStorage(Prefs.showChecks) private var showChecks = false
    @AppStorage(Prefs.notifyKey(.myPRs)) private var notifyMyPRs = true
    @AppStorage(Prefs.notifyKey(.reviewRequests)) private var notifyRequests = true
    @AppStorage(Prefs.notifyKey(.reviewing)) private var notifyReviewing = true
    @AppStorage(Prefs.notifyKey(.merged)) private var notifyMerged = true
    @AppStorage(Prefs.notifyKey(.checks)) private var notifyChecks = true
    private let loginItem = LoginItem.shared

    var body: some View {
        Form {
            Section("Polling") {
                Stepper("Check every \(Int(pollMinutes)) min", value: $pollMinutes, in: 1...30, step: 1)
                Stepper("Hide team requests idle for \(staleDays) days", value: $staleDays, in: 1...365)
                Toggle("Ignore bots (hide their PRs, mute their comments)", isOn: $ignoreBots)
            }
            Section("Panel") {
                Toggle("Show lines added and removed", isOn: $showLineCounts)
                    // Fetch the counts now instead of at the next poll.
                    .onChange(of: showLineCounts) { _, on in if on { PRStore.shared.refreshNow() } }
                Toggle("Show checks and merge conflicts on my PRs", isOn: $showChecks)
                    .onChange(of: showChecks) { _, on in if on { PRStore.shared.refreshNow() } }
            }
            Section("Notify me about") {
                Toggle("Reviews and comments on my PRs", isOn: $notifyMyPRs)
                Toggle("New review requests", isOn: $notifyRequests)
                Toggle("Activity on PRs I review", isOn: $notifyReviewing)
                Toggle("Merges of my PRs and PRs I review", isOn: $notifyMerged)
                Toggle("Failed checks on my PRs", isOn: $notifyChecks)
                    .disabled(!showChecks)
            }
            Section {
                // A closure, not `set: loginItem.set`: passing the method crashes Swift 6.3's compiler.
                Toggle("Launch at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
                if let error = loginItem.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(AppInfo.name).font(.headline)
                        Text("Version \(AppInfo.version)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link(destination: AppInfo.repo) {
                        Label("GitHub", systemImage: "arrow.up.right.square")
                    }
                    .help(AppInfo.repo.absoluteString)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}

@MainActor @Observable
final class LoginItem {
    static let shared = LoginItem()

    private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    private(set) var error: String?

    func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
