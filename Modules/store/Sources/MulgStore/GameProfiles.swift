// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MulgContracts
import MulgLibrary

/// What worked for one game, from the reviewed `results/game-profiles.json` in this repo
/// (PLAN.md §8.2).
public struct GameProfile: Codable, Sendable, Equatable {
    public var bundleIdentifier: String
    /// The device identifier that worked, such as "iPad17,3".
    public var deviceModel: String?
    /// A `ResolutionMode` raw value.
    public var resolution: Int?
    /// "native" or "metalFX".
    public var graphicsRoute: String?
    public var works: Bool
    public var fps120: Bool
    public var metalFXTested: Bool
    public var testedOn: String
    public var macOSVersion: String

    public init(bundleIdentifier: String, deviceModel: String? = nil, resolution: Int? = nil,
                graphicsRoute: String? = nil, works: Bool, fps120: Bool = false, metalFXTested: Bool = false,
                testedOn: String, macOSVersion: String) {
        self.bundleIdentifier = bundleIdentifier
        self.deviceModel = deviceModel
        self.resolution = resolution
        self.graphicsRoute = graphicsRoute
        self.works = works
        self.fps120 = fps120
        self.metalFXTested = metalFXTested
        self.testedOn = testedOn
        self.macOSVersion = macOSVersion
    }

    /// Fills in settings for a newly installed game. Only settings still at their default
    /// are touched, so the user's own settings always win.
    public func applyDefaults(to settings: inout GameSettings) {
        let fresh = GameSettings(bundleIdentifier: settings.bundleIdentifier)
        if let deviceModel, settings.iosDeviceModel == fresh.iosDeviceModel {
            settings.iosDeviceModel = deviceModel
        }
        if let resolution, settings.resolution == fresh.resolution {
            settings.resolution = resolution
        }
        // The MetalFX layer stays opt-in with its one-time warning (§15), so a "metalFX"
        // route only shows as a badge.
    }

    /// The library's compatibility badges (§13.3).
    public enum Badge: Sendable, Equatable {
        case works, fps120, metalFXTested
        case bestIdentifier(String)
        case notTested
    }

    public static func badges(for profile: GameProfile?) -> [Badge] {
        guard let profile else { return [.notTested] }
        var badges: [Badge] = profile.works ? [.works] : []
        if profile.fps120 { badges.append(.fps120) }
        if profile.metalFXTested { badges.append(.metalFXTested) }
        if let model = profile.deviceModel { badges.append(.bestIdentifier(model)) }
        return badges
    }
}

public struct GameProfileFeed: Codable, Sendable, Equatable {
    public var version: Int
    public var games: [GameProfile]

    public init(version: Int = 1, games: [GameProfile] = []) {
        self.version = version
        self.games = games
    }

    public func profile(for bundleIdentifier: String) -> GameProfile? {
        games.first { $0.bundleIdentifier == bundleIdentifier }
    }
}

/// The fork's GitHub repository, "owner/name", from the app's Info.plist (`MulgRepository`).
/// Without it the app downloads nothing and offers no sharing.
public enum MulgRepository {
    public static func current(bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: "MulgRepository") as? String
    }

    public static func profilesURL(_ repository: String) -> URL? {
        URL(string: "https://raw.githubusercontent.com/\(repository)/main/results/game-profiles.json")
    }
}

/// The downloaded feed, kept in the container and refreshed at most once a day (§8.2).
public struct GameProfileCache: Sendable {
    public let file: URL

    public init(paths: ContainerPaths = .current()) {
        file = paths.mulgStateDirectory.appendingPathComponent("game-profiles.json")
    }

    public func load() -> GameProfileFeed? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(GameProfileFeed.self, from: $0) }
    }

    public func isStale(now: Date = .now) -> Bool {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return modified.map { now.timeIntervalSince($0) >= 24 * 60 * 60 } ?? true
    }

    /// Returns the cached feed, downloading a new one first when the cache is a day old.
    /// A download that fails or does not decode leaves the cache as it was.
    public func refresh(
        from url: URL,
        now: Date = .now,
        fetch: @Sendable (URL) async throws -> Data = { try await URLSession.shared.data(from: $0).0 }
    ) async throws -> GameProfileFeed {
        if !isStale(now: now), let cached = load() {
            return cached
        }
        let data = try await fetch(url)
        let feed = try JSONDecoder().decode(GameProfileFeed.self, from: data)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return feed
    }
}

/// "Share this game's result": a pre-filled GitHub issue the user reviews and submits
/// themselves (§8.2). The app sends nothing on its own.
public enum ShareResult {
    public static func issueURL(repository: String, settings: GameSettings, works: Bool, mac: MacInfo) -> URL? {
        let route = settings.mulg.graphics.metalFX.enabled ? "metalFX" : "native"
        let body = """
            Game: \(settings.bundleIdentifier)
            Works: \(works ? "yes" : "no")
            Device identifier: \(settings.iosDeviceModel)
            Resolution mode: \(settings.resolution)
            Graphics route: \(route)
            Frame rate reached (fill in):
            Mac: \(mac.model)
            macOS: \(mac.systemVersion)
            Mulg: \(MulgVersion.current)
            """
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: "Game result: \(settings.bundleIdentifier)"),
            URLQueryItem(name: "labels", value: "game-result"),
            URLQueryItem(name: "body", value: body)
        ]
        return components?.url
    }
}

/// Game updates offered by IPA sources (PLAN.md §13.3).
public enum GameUpdates {
    /// The newest offered version above the installed one, or nil. An unknown installed
    /// version never gets an offer.
    public static func newest(installed: String, offered: [String]) -> String? {
        guard !installed.isEmpty else { return nil }
        return offered.filter { isNewer($0, than: installed) }.max { isNewer($1, than: $0) }
    }

    /// Compares dotted versions part by part, so 1.10 is above 1.9 and 2.0 equals 2.
    public static func isNewer(_ version: String, than other: String) -> Bool {
        let lhs = parts(version), rhs = parts(other)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// "5.2.1b" gives [5, 2, 1]: the leading digits of each part.
    private static func parts(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
#endif
