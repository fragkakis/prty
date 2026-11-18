import AppKit
import PRtyTimeCore
import SwiftUI

// Renders docs/screenshot-{light,dark}.png from demo data. Not part of the build; to use it:
// 1. Copy this file into Sources/PRtyTime/.
// 2. In PRStore.swift, drop `private(set)` from buckets, unread, lastRefresh and diffStats;
//    in Avatar.swift, from AvatarStore.images.
// 3. Start AppDelegate.applicationDidFinishLaunching with
//    `if let dir = ProcessInfo.processInfo.environment["PRTY_SHOT"] { Screenshot.run(to: dir); return }`
// 4. `make bundle`, then `PRTY_SHOT=<dir> ".build/PRty Time.app/Contents/MacOS/PRtyTime"`.
// 5. Copy the PNGs to docs/ and revert steps 1-3.
@MainActor
enum Screenshot {
    static func run(to dir: String) {
        let now = Date()
        func avatarURL(_ login: String) -> URL { URL(string: "https://example.invalid/\(login).png")! }
        func pr(_ id: String, _ repo: String, _ number: Int, _ title: String, by author: String, _ minutes: Double,
                teams: [String] = [], draft: Bool = false, decision: ReviewDecision? = nil) -> PullRequest {
            PullRequest(
                id: id, number: number, title: title, url: URL(string: "https://github.com/\(repo)/pull/\(number)")!,
                isDraft: draft, updatedAt: now.addingTimeInterval(-minutes * 60),
                author: Actor(login: author, avatarURL: avatarURL(author)), repo: repo,
                requestedTeams: teams, hasDetails: true, reviewDecision: decision
            )
        }
        let store = PRStore.shared
        store.buckets = [
            .direct: [
                pr("d1", "acme/api", 482, "Add rate limiting to the public API", by: "alice", 12),
                pr("d2", "acme/web", 1290, "Fix flaky checkout test", by: "bob", 190),
            ],
            .team: [
                pr("t1", "acme/api", 479, "Bump Postgres driver to 3.2", by: "carol", 40, teams: ["backend"]),
                pr("t2", "acme/web", 1287, "New onboarding flow", by: "dan", 26 * 60, teams: ["frontend"]),
                pr("t3", "acme/infra", 77, "Move workers to arm64", by: "erin", 50 * 60, teams: ["platform"]),
                pr("t4", "acme/mobile", 311, "Dark mode for the settings screen", by: "frank", 5 * 1440, teams: ["mobile"]),
            ],
            .reviewed: [
                pr("r1", "acme/api", 470, "Cache feature flags in memory", by: "grace", 2 * 1440, decision: .approved),
            ],
            .mine: [
                pr("m1", "acme/api", 485, "Retry webhooks with exponential backoff", by: "you", 25, decision: .approved),
                pr("m2", "acme/web", 1292, "Speed up search suggestions", by: "you", 4 * 60, decision: .reviewRequired),
                pr("m3", "acme/api", 480, "Remove legacy v1 endpoints", by: "you", 1440, decision: .changesRequested),
                pr("m4", "acme/infra", 79, "Add staging smoke tests", by: "you", 3 * 1440, draft: true, decision: .reviewRequired),
            ],
        ]
        store.unread = ["d1", "t2", "m1"]
        store.lastRefresh = now.addingTimeInterval(-30)
        let counts: [String: (Int, Int)] = [
            "d1": (148, 12), "d2": (6, 9), "t1": (2, 2), "t2": (1_240, 310), "t3": (87, 45), "t4": (214, 36),
            "r1": (64, 8), "m1": (96, 14), "m2": (41, 17), "m3": (12, 1_870), "m4": (230, 0),
        ]
        store.diffStats = counts.mapValues { DiffStat(additions: $0.0, deletions: $0.1) }
        for login in ["alice", "bob", "carol", "dan", "erin", "frank", "grace"] {
            AvatarStore.shared.images[avatarURL(login)] = identicon(login)
        }

        Task {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                var shots: [NSImage] = []
                for tab in [PanelTab.review, .mine] {
                    PanelState.shared.tab = tab
                    shots.append(await render(appearance))
                }
                let png = compose(shots, dark: name == "dark")
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("screenshot-\(name).png"))
            }
            NSApp.terminate(nil)
        }
    }

    /// A GitHub-style identicon: a mirrored 5x5 grid in a color derived from the login.
    static func identicon(_ login: String) -> NSImage {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in login.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let color = NSColor(hue: CGFloat(hash % 360) / 360, saturation: 0.5, brightness: 0.78, alpha: 1)
        let bits = hash >> 12
        let px = 140
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.94, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: px, height: px).fill()
        color.setFill()
        let cell: CGFloat = 24, inset: CGFloat = 10
        for col in 0..<3 {
            for row in 0..<5 where (bits >> UInt64(col * 5 + row)) & 1 == 1 {
                for c in Set([col, 4 - col]) {
                    NSRect(x: inset + CGFloat(c) * cell, y: inset + CGFloat(row) * cell, width: cell, height: cell).fill()
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 70, height: 70))
        image.addRepresentation(rep)
        return image
    }

    static func render(_ appearance: NSAppearance.Name) async -> NSImage {
        let view = NSHostingView(rootView: MenuContent(store: PRStore.shared).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 460, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(800))
        let size = view.fittingSize
        window.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(400))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        window.orderOut(nil)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Both panels side by side with rounded corners and a shadow, at 2x.
    static func compose(_ panels: [NSImage], dark: Bool) -> Data {
        let pad: CGFloat = 36, gap: CGFloat = 28, radius: CGFloat = 12
        let height = panels.map(\.size.height).max()! + 2 * pad
        let width = panels.map(\.size.width).reduce(0, +) + gap * CGFloat(panels.count - 1) + 2 * pad
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let scale = NSAffineTransform()
        scale.scale(by: 2)
        scale.concat()
        var x = pad
        for panel in panels {
            let rect = NSRect(x: x, y: height - pad - panel.size.height, width: panel.size.width, height: panel.size.height)
            let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(dark ? 0.5 : 0.22)
            shadow.shadowBlurRadius = 22
            shadow.shadowOffset = NSSize(width: 0, height: -8)
            shadow.set()
            NSColor.black.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            panel.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()

            (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.12)).setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
            border.lineWidth = 0.5
            border.stroke()
            x += panel.size.width + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
