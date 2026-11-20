import Foundation

/// A published PRty Time release, from GitHub's `releases/latest`.
public struct Release: Sendable, Equatable {
    /// "0.7.0", without the tag's "v".
    public var version: String
    /// The release page, with the zip and the install notes.
    public var url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }

    static func decode(_ body: Data) throws -> Release {
        struct Payload: Decodable {
            var tagName: String
            var htmlUrl: URL
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(Payload.self, from: body)
        let version = payload.tagName.hasPrefix("v") ? String(payload.tagName.dropFirst()) : payload.tagName
        return Release(version: version, url: payload.htmlUrl)
    }
}

public enum UpdateCheck {
    public static let interval: TimeInterval = 86_400

    /// A day since the last check, or never checked. A last check in the
    /// future (the clock was moved back) counts as due too.
    public static func isDue(lastChecked: Date?, now: Date = Date()) -> Bool {
        guard let lastChecked else { return true }
        return now < lastChecked || now.timeIntervalSince(lastChecked) >= interval
    }

    /// Whether `version` is later than `current`, comparing "1.2.3" part by
    /// part, a missing part counting as 0. Never when either isn't a version,
    /// such as "dev" when run outside the app bundle.
    public static func isNewer(_ version: String, than current: String) -> Bool {
        guard var new = parts(version), var old = parts(current) else { return false }
        let count = max(new.count, old.count)
        new += Array(repeating: 0, count: count - new.count)
        old += Array(repeating: 0, count: count - old.count)
        return old.lexicographicallyPrecedes(new)
    }

    private static func parts(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }
}
