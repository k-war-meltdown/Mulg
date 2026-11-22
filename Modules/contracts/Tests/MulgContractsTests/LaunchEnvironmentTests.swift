import Foundation
import Testing
@testable import MulgContracts

@Suite("Environment before game constructors")
struct LaunchEnvironmentTests {
    @Test func hostBundleAndProcessMetadataDoesNotLeakIntoTheGame() {
        var settings = GameSettings(bundleIdentifier: "launch.env")
        settings.mulg.engine.environment = ["GAME_SERVER": "cloud"]
        let inherited = ["CFProcessPath": "/Applications/Mulg.app/Contents/MacOS/Mulg",
                         "__CFBundleIdentifier": "io.mulg.Mulg", "__CFBundleURL": "/Applications/Mulg.app",
                         "APP_SANDBOX_CONTAINER_ID": "io.mulg.Mulg", "XPC_SERVICE_NAME": "host.service",
                         "XPC_FLAGS": "1", "PATH": "/bin", "LANG": "en_US.UTF-8"]
        #expect(LaunchEnvironment.make(settings, inherited: inherited)
            == ["PATH": "/bin", "LANG": "en_US.UTF-8", "GAME_SERVER": "cloud"])
    }

    @Test func inheritedMetalAndDyldFlagsAreScrubbedAndGameOverridesAreValidated() {
        var settings = GameSettings(bundleIdentifier: "launch.env")
        settings.mulg.engine.environment = ["GAME_SERVER": "cloud", "DYLD_INSERT_LIBRARIES": "/wrong", "BAD=NAME": "x", "NUL": "a\0b"]
        let inherited = Dictionary(uniqueKeysWithValues: LaunchEnvironment.managedMetalKeys.map { ($0, "stale") })
            .merging(["PATH": "/bin", "DYLD_LIBRARY_PATH": "/wrong", "GAME_SERVER": "old"]) { _, value in value }
        let result = LaunchEnvironment.make(settings, inherited: inherited)
        #expect(result == ["PATH": "/bin", "GAME_SERVER": "cloud"])
    }
    @Test func externalMetalToolsAreNeverSetEvenFromOldSettingsOrCustomVariables() {
        var settings = GameSettings(bundleIdentifier: "launch.env")
        settings.metalHUD = true; settings.mulg.diagnostics.hudLogging = true
        settings.mulg.diagnostics.debugger = true; settings.mulg.diagnostics.debugGraphics = true
        settings.mulg.diagnostics.debugShaders = true
        settings.mulg.engine.environment = ["MTL_DEBUG_LAYER": "custom", "GAME_SERVER": "cloud"]
        let inherited = ["MTL_HUD_ENABLED": "1", "METAL_DEVICE_WRAPPER_TYPE": "1", "HOME": "/Users/x"]
        let normal = LaunchEnvironment.make(settings, inherited: inherited)
        #expect(normal == ["GAME_SERVER": "cloud", "HOME": "/Users/x"])
        #expect(LaunchEnvironment.make(settings, inherited: inherited, minimalRecovery: true) == normal)
        #expect(LaunchEnvironment.overrides(settings) == ["GAME_SERVER": "cloud"])
    }
    @Test(arguments: ["3", "4", "{\"unfinishedLaunches\":4}", "{\"unfinishedLaunches\":3}", "corrupt", "-1"])
    func hostRecoveryReadsTheSameCounterWithoutIncrementing(_ value: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(value.utf8).write(to: file)
        #expect(LaunchEnvironment.needsMinimalRecovery(marker: file) == value.contains("4"))
        #expect(try String(contentsOf: file, encoding: .utf8) == value)
    }
}
