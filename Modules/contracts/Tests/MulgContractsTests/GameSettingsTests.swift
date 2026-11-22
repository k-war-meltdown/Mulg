import Foundation
import Testing
@testable import MulgContracts

@Suite("GameSettings")
struct GameSettingsTests {
    @Test func legacyDeltaKeepsNewerEditsAndUnknownKeysAndResetIsAtomic() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(paths: ContainerPaths(home: root)), id = "audit.settings"
        func encode(_ tree: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: tree, format: .xml, options: 0)
        }
        let base = try encode(["sensitivity": 50, "keymapping": true])
        _ = try store.saveLegacy(base, basedOn: nil, bundleIdentifier: id)
        _ = try store.saveLegacy(encode(["sensitivity": 88, "future": ["enabled": true]]), basedOn: base, bundleIdentifier: id)
        let result = try store.saveLegacy(encode(["sensitivity": 50, "keymapping": false]), basedOn: base, bundleIdentifier: id)
        let tree = try #require(try PropertyListSerialization.propertyList(from: result, format: nil) as? [String: Any])
        #expect(tree["sensitivity"] as? Int == 88 && tree["keymapping"] as? Bool == false)
        #expect((tree["future"] as? [String: Any])?["enabled"] as? Bool == true)
        let reset = try store.saveLegacy(base, basedOn: nil, bundleIdentifier: id, reset: true)
        #expect(try PropertyListSerialization.propertyList(from: reset, format: nil) as? NSDictionary ==
                PropertyListSerialization.propertyList(from: base, format: nil) as? NSDictionary)
    }
    @Test("An empty settings file decodes to the defaults")
    func emptyFileGivesDefaults() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: [String: Any](), format: .xml, options: 0)
        let settings = try SettingsStore.decode(data)
        #expect(settings == GameSettings())
    }

    @Test("A new game starts at desktop resolution and 120 FPS, with every Mac core and no downscaling")
    func newGameDefaults() {
        let settings = GameSettings()
        #expect(settings.resolution == ResolutionMode.display.rawValue)
        #expect(settings.mulg.display.frameRateCap == 120 && settings.mulg.display.uncapFrameRate)
        #expect(!settings.mulg.display.batterySaverOnBattery && !settings.mulg.display.thermalGuard)
        #expect(!settings.mulg.display.backgroundThrottle && !settings.mulg.display.frameCapBelowRefresh)
        #expect(settings.mulg.graphics.fullResolution && settings.mulg.graphics.forceRenderResolution)
        #expect(settings.iosDeviceModel == "iPad17,3")
        #expect(!settings.mulg.identity.matchDeviceCPU)  // the game sees every Mac core
        #expect(!settings.mulg.diagnostics.debugger && !settings.metalHUD && !settings.mulg.diagnostics.performanceOverlay)
        #expect(!settings.mulg.graphics.metalFX.enabled && !settings.mulg.graphics.metalFX.automatic)
    }

    @Test("A saved resolution is kept, whatever the default is")
    func savedResolutionIsKept() throws {
        var saved = GameSettings()
        saved.resolution = ResolutionMode.p1440.rawValue
        let data = try PropertyListEncoder().encode(saved)
        #expect(try SettingsStore.decode(data).resolution == ResolutionMode.p1440.rawValue)
    }

    @Test("A partial upstream file keeps its values and fills the rest with defaults")
    func partialUpstreamFile() throws {
        let upstream: [String: Any] = [
            "bundleIdentifier": "com.miHoYo.GenshinImpact",
            "iosDeviceModel": "iPad16,6",
            "resolution": 3,
            "sensitivity": 75.0,
            "discordActivity": ["enable": false]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: upstream, format: .xml, options: 0)
        let settings = try SettingsStore.decode(data)

        #expect(settings.bundleIdentifier == "com.miHoYo.GenshinImpact")
        #expect(settings.iosDeviceModel == "iPad16,6")
        #expect(settings.resolution == 3)
        #expect(settings.sensitivity == 75)
        #expect(settings.discordActivity.enable == false)
        #expect(settings.discordActivity.applicationID == "")
        #expect(settings.keymapping == true)
        #expect(settings.mulg == ModuleSettings())
    }

    @Test("Unknown keys from other versions are ignored")
    func unknownKeysIgnored() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["someFutureKey": true, "keymapping": false], format: .xml, options: 0)
        let settings = try SettingsStore.decode(data)
        #expect(settings.keymapping == false)
    }

    @Test("Settings survive an encode and decode round trip")
    func roundTrip() throws {
        var settings = GameSettings(bundleIdentifier: "com.example.game")
        settings.iosDeviceModel = "iPad17,3"
        settings.mulg.display.reportProMotion = true
        settings.mulg.graphics.metalFX.enabled = true
        settings.mulg.graphics.metalFX.preset = .performance
        settings.mulg.controls.playMode = .virtualController
        settings.mulg.controls.gyro.source = .mouse
        settings.mulg.engine.disabledModules = ["graphics"]

        let decoded = try SettingsStore.decode(try SettingsStore.encode(settings))
        #expect(decoded == settings)
    }

    @Test("Fork settings are stored under the single `mulg` key, keeping upstream keys untouched")
    func forkSettingsNamespaced() throws {
        let data = try SettingsStore.encode(GameSettings())
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["mulg"] is [String: Any])
        #expect(plist["iosDeviceModel"] as? String == "iPad17,3")
        #expect(plist["display"] == nil)
    }

    @Test("Unknown enum values fall back to the default instead of failing the whole file")
    func unknownEnumValues() throws {
        let file: [String: Any] = [
            "mulg": [
                "graphics": ["metalFX": ["preset": "hyper", "enabled": true]],
                "controls": ["playMode": "telepathy", "cursorKeyBehaviour": "toggle"]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: file, format: .xml, options: 0)
        let settings = try SettingsStore.decode(data)
        #expect(settings.mulg.graphics.metalFX.preset == .balanced)
        #expect(settings.mulg.graphics.metalFX.enabled == true)
        #expect(settings.mulg.controls.playMode == .touch)
        #expect(settings.mulg.controls.cursorKeyBehaviour == .toggle)
    }

    @Test("MetalFX and hold-Option cursor defaults match the plan")
    func planDefaults() {
        let settings = GameSettings()
        #expect(settings.mulg.graphics.metalFX.enabled == false)
        #expect(settings.mulg.graphics.metalFX.preset == .balanced)
        #expect(settings.mulg.controls.cursorKeyBehaviour == .hold)
        #expect(settings.mulg.controls.cursorKey == "option")
        #expect(settings.mulg.engine.allowUnverifiedPlugins == false)
    }

    @Test("Games set up before the shader setting existed get it switched on")
    func shaderCompilationDefaultsOn() throws {
        let file: [String: Any] = ["mulg": ["engine": ["keepGameSDKVersion": true]]]
        let data = try PropertyListSerialization.data(fromPropertyList: file, format: .xml, options: 0)
        let settings = try SettingsStore.decode(data)
        #expect(settings.mulg.engine.keepGameSDKVersion)
        #expect(settings.mulg.engine.maximizeShaderCompilation)
    }
}

@Suite("MetalFX presets")
struct MetalFXPresetTests {
    @Test("Render sizes are scaled per side and rounded down to even numbers",
          arguments: [
              (MetalFXPreset.quality, 1970, 1232),
              (.balanced, 1714, 1072),
              (.performance, 1510, 944),
              (.ultraPerformance, 1280, 800)
          ])
    func renderSize(preset: MetalFXPreset, width: Int, height: Int) {
        let size = preset.renderSize(forOutputWidth: 2560, height: 1600)
        #expect(size.width == width)
        #expect(size.height == height)
    }

    @Test("Tiny outputs never produce a zero-sized render target")
    func neverZero() {
        let size = MetalFXPreset.ultraPerformance.renderSize(forOutputWidth: 1, height: 1)
        #expect(size.width == 2)
        #expect(size.height == 2)
    }

    @Test("Saving a snapshot keeps newer values another writer saved to other settings")
    func mergeKeepsNewerValues() {
        var base = GameSettings(bundleIdentifier: "com.example.game")
        base.mulg.engine.environment = ["A": "1", "B": "2"]
        var edited = base
        edited.sensitivity = 80
        edited.mulg.engine.environment["B"] = nil
        var current = base
        current.resolution = 3
        current.mulg.engine.environment["C"] = "3"

        let merged = SettingsStore.merge(base: base, edited: edited, onto: current)
        #expect(merged.sensitivity == 80)
        #expect(merged.resolution == 3)
        #expect(merged.mulg.engine.environment == ["A": "1", "C": "3"])
        #expect(SettingsStore.merge(base: base, edited: edited, onto: base) == edited)
    }
}

@Suite struct EnvironmentVariableTests {
    @Test func namesTheRuntimeWouldIgnore() {
        #expect(EngineSettings.environmentProblem(name: "MTL_HUD_ENABLED", value: "1") == nil)
        #expect(EngineSettings.environmentProblem(name: "A", value: "") == nil)
        #expect(EngineSettings.environmentProblem(name: "", value: "1") == .emptyName)
        #expect(EngineSettings.environmentProblem(name: "A=B", value: "1") == .equalsInName)
        #expect(EngineSettings.environmentProblem(name: "A\0", value: "1") == .nullCharacter)
        #expect(EngineSettings.environmentProblem(name: "A", value: "1\0") == .nullCharacter)
        #expect(EngineSettings.environmentProblem(name: "DYLD_INSERT_LIBRARIES", value: "x") == .dyldName)
    }
}
