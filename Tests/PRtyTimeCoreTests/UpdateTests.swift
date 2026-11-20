import Foundation
import Testing
@testable import PRtyTimeCore

@Suite struct UpdateTests {
    @Test func comparesVersionsPartByPart() {
        #expect(UpdateCheck.isNewer("0.7.0", than: "0.6.0"))
        #expect(UpdateCheck.isNewer("0.10.0", than: "0.9.0"))
        #expect(UpdateCheck.isNewer("1.0.1", than: "1.0"))
        #expect(!UpdateCheck.isNewer("0.6.0", than: "0.6.0"))
        #expect(!UpdateCheck.isNewer("1.0", than: "1.0.0"))
        #expect(!UpdateCheck.isNewer("0.5.9", than: "0.6.0"))
    }

    @Test func somethingThatIsntAVersionIsNeverNewerOrOutdated() {
        #expect(!UpdateCheck.isNewer("0.7.0", than: "dev"))
        #expect(!UpdateCheck.isNewer("dev", than: "0.6.0"))
        #expect(!UpdateCheck.isNewer("0.7.0-beta", than: "0.6.0"))
        #expect(!UpdateCheck.isNewer("", than: "0.6.0"))
    }

    @Test func dueADayAfterTheLastCheck() {
        #expect(UpdateCheck.isDue(lastChecked: nil, now: now))
        #expect(!UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-86_399), now: now))
        #expect(UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-86_400), now: now))
        #expect(UpdateCheck.isDue(lastChecked: now.addingTimeInterval(3_600), now: now))
    }

    @Test func decodesTheLatestRelease() throws {
        let json = #"{"tag_name": "v0.7.0", "html_url": "https://github.com/fragkakis/prty-time/releases/tag/v0.7.0", "draft": false, "prerelease": false}"#
        let release = try Release.decode(Data(json.utf8))
        #expect(release == Release(version: "0.7.0", url: URL(string: "https://github.com/fragkakis/prty-time/releases/tag/v0.7.0")!))
    }
}
