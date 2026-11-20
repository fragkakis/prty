import AppKit
import Observation
import PRtyTimeCore
import SwiftUI

/// How to get a newer release: Homebrew installs update with brew, others
/// download the zip from the release page.
@MainActor @Observable
final class UpdateHelp {
    static let shared = UpdateHelp()
    static let brewCommand = "brew upgrade --cask prty-time"

    /// The cask's folder exists, under Apple silicon's or Intel's Homebrew prefix.
    let viaHomebrew = ["/opt/homebrew/Caskroom/prty-time", "/usr/local/Caskroom/prty-time"]
        .contains { FileManager.default.fileExists(atPath: $0) }
    /// The brew command was just copied.
    private(set) var copied = false

    func copyBrewCommand() {
        NSPasteboard.general.copy(Self.brewCommand)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// "Copy brew command" or "Download", for a newer release.
struct UpdateButton: View {
    let release: Release
    /// Called after opening the release page, e.g. to close the panel.
    var opened: () -> Void = {}
    private let help = UpdateHelp.shared

    var body: some View {
        if help.viaHomebrew {
            Button(help.copied ? "Copied" : "Copy brew command") { help.copyBrewCommand() }
                .help(UpdateHelp.brewCommand)
        } else {
            Button("Download") {
                NSWorkspace.shared.open(release.url)
                opened()
            }
            .help(release.url.absoluteString)
        }
    }
}
