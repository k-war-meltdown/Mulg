// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MulgContracts
import MulgLibrary
import Testing
@testable import MulgStore

let sample = GameProfile(bundleIdentifier: "com.example.game", deviceModel: "iPad16,5",
                         resolution: ResolutionMode.p1440.rawValue, graphicsRoute: "metalFX",
                         works: true, fps120: true, metalFXTested: true, testedOn: "Mac17,1", macOSVersion: "27.0")

@Suite struct GameProfileTests {
    @Test func defaultsNeverOverrideTheUser() {
        var fresh = GameSettings(bundleIdentifier: "com.example.game")
        sample.applyDefaults(to: &fresh)
        #expect(fresh.iosDeviceModel == "iPad16,5" && fresh.resolution == ResolutionMode.p1440.rawValue)
        #expect(!fresh.mulg.graphics.metalFX.enabled)

        var chosen = GameSettings(bundleIdentifier: "com.example.game")
        chosen.resolution = ResolutionMode.p1080.rawValue
        sample.applyDefaults(to: &chosen)
        #expect(chosen.resolution == ResolutionMode.p1080.rawValue)
    }

    @Test func badges() {
        #expect(GameProfile.badges(for: nil) == [.notTested])
        #expect(GameProfile.badges(for: sample) == [.works, .fps120, .metalFXTested, .bestIdentifier("iPad16,5")])
    }

    @Test func repositoryFileDecodes() throws {
        // The reviewed file at the repository root must always decode.
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("results/game-profiles.json")
        _ = try JSONDecoder().decode(GameProfileFeed.self, from: Data(contentsOf: file))
    }
}

@Suite struct GameProfileCacheTests {
    @Test func downloadsAtMostOnceADay() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mulg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = GameProfileCache(paths: ContainerPaths(home: home))
        let feed = GameProfileFeed(games: [sample])
        let data = try JSONEncoder().encode(feed)
        let url = try #require(URL(string: "https://example.invalid/game-profiles.json"))

        #expect(try await cache.refresh(from: url, fetch: { _ in data }) == feed)
        // Fresh cache: no download (the fetch would fail).
        #expect(try await cache.refresh(from: url, fetch: { _ in throw URLError(.notConnectedToInternet) }) == feed)
        // A day later a broken download keeps the old cache.
        let tomorrow = Date.now.addingTimeInterval(25 * 60 * 60)
        await #expect(throws: DecodingError.self) {
            try await cache.refresh(from: url, now: tomorrow, fetch: { _ in Data("nope".utf8) })
        }
        #expect(cache.load() == feed)
    }
}

@Suite struct ShareResultTests {
    @Test func prefilledIssueHasNoAccountData() throws {
        var settings = GameSettings(bundleIdentifier: "com.example.game")
        settings.discordActivity.applicationID = "secret"
        let url = try #require(ShareResult.issueURL(repository: "owner/Mulg", settings: settings, works: true,
                                                    mac: MacInfo(model: "Mac17,1", systemVersion: "27.0")))
        #expect(url.absoluteString.hasPrefix("https://github.com/owner/Mulg/issues/new?"))
        let body = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value
        #expect(body?.contains("Mac: Mac17,1") == true)
        #expect(!url.absoluteString.contains("secret"))
    }
}

@Suite struct GameUpdateTests {
    @Test func versions() {
        #expect(GameUpdates.isNewer("1.10", than: "1.9"))
        #expect(!GameUpdates.isNewer("2.0", than: "2"))
        #expect(GameUpdates.isNewer("5.2.1b", than: "5.2"))
        #expect(GameUpdates.newest(installed: "1.0", offered: ["1.0", "1.2", "1.1"]) == "1.2")
        #expect(GameUpdates.newest(installed: "2", offered: ["2.0", "1.9"]) == nil)
        #expect(GameUpdates.newest(installed: "", offered: ["1.0"]) == nil)
    }
}
#endif
