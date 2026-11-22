import Testing
import Foundation
@testable import MulgContracts

struct RetinaTests {
    @Test func retinaDefaultsOnAndDecodesMissingKey() throws {
        #expect(DisplaySettings().retina)
        let decoded = try JSONDecoder().decode(DisplaySettings.self, from: Data("{}".utf8))
        #expect(decoded.retina)
    }

    @Test func retinaOffUsesLiveWindowInsteadOfSavedRenderHeight() {
        var settings = GameSettings()
        settings.resolution = ResolutionMode.display.rawValue
        settings.windowWidth = 1440; settings.windowHeight = 900; settings.customScaler = 2
        #expect(settings.targetRenderHeight == 1800)
        settings.mulg.display.retina = false
        // Every mode must use the current window size, including after a resize.
        for mode in ResolutionMode.allCases {
            settings.resolution = mode.rawValue
            #expect(settings.targetRenderHeight == nil)
        }
        settings.resolution = ResolutionMode.display.rawValue
        settings.mulg.display.retina = true
        #expect(settings.targetRenderHeight == 1800)
    }

    @Test func retinaTogglePersistsWithoutChangingOtherSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "retina.persistence"
        let store = SettingsStore(paths: ContainerPaths(home: root))
        var settings = GameSettings(bundleIdentifier: id)
        settings.mulg.graphics.fullResolution = true
        settings.mulg.graphics.forceRenderResolution = true
        settings.mulg.graphics.metalFX.enabled = true
        settings.mulg.display.frameRateCap = 60
        for enabled in [false, true] {
            settings.mulg.display.retina = enabled
            try store.save(settings)
            let loaded = store.load(bundleIdentifier: id)
            #expect(loaded.problem == nil)
            #expect(loaded.settings == settings)
        }
    }
}
