#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MulgContracts
import Testing
@testable import MulgLibrary

@Suite struct PointerInputCompatibilityTests {
    @Test(arguments: ["com.riotgames.league.teamfighttactics", "com.riotgames.league.teamfighttactics.kr"])
    func tftVirtualMouseRestoresOnlyManagedTouchPolicy(_ identifier: String) throws {
        let app = try InstallerTests().makeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        var settings = GameSettings(bundleIdentifier: "com.example.game")
        try GameInstaller.synchronizePointerInput(in: app, settings: settings)
        #expect(GameInstaller.infoPlist(app)?["MulgManagedDirectPointerInput"] != nil)
        settings.bundleIdentifier = identifier
        try GameInstaller.synchronizePointerInput(in: app, settings: settings)
        #expect(GameInstaller.infoPlist(app)?["UIApplicationSupportsIndirectInputEvents"] == nil)
        #expect(GameInstaller.infoPlist(app)?["MulgManagedDirectPointerInput"] == nil)
        #expect(try GameInstaller.pointerInputIsCurrent(in: app, settings: settings))
    }

    @Test func installSealsNativeTouchPolicyBeforeSigning() async throws {
        let app = try InstallerTests().makeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        var settings = GameSettings(bundleIdentifier: "com.example.game")
        try await GameInstaller.install(app: app,
            options: .init(runtimePath: "/r/MulgRuntime", entitlements: URL(fileURLWithPath: "/e.plist")),
            settings: &settings, preflight: { _, _ in }, sign: { plan in
                #expect(GameInstaller.infoPlist(plan.app)?["UIApplicationSupportsIndirectInputEvents"] as? Bool == false)
            })
        let plist = app.appendingPathComponent("Info.plist")
        let sealed = try Data(contentsOf: plist)
        #expect(try GameInstaller.pointerInputIsCurrent(in: app, settings: settings))
        try GameInstaller.synchronizePointerInput(in: app, settings: settings)
        #expect(try Data(contentsOf: plist) == sealed)
        try GameInstaller.restorePointerInput(in: app)
        #expect(GameInstaller.infoPlist(app)?["UIApplicationSupportsIndirectInputEvents"] == nil)
        #expect(GameInstaller.infoPlist(app)?["MulgManagedDirectPointerInput"] == nil)
    }

    @Test func disabledMappingRestoresNativeDeclarationAndInvalidatesFreshness() throws {
        let app = try InstallerTests().makeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        var settings = GameSettings()
        try GameInstaller.synchronizePointerInput(in: app, settings: settings)
        settings.mulg.engine.disabledModules = ["controls"]
        #expect(try !GameInstaller.pointerInputIsCurrent(in: app, settings: settings))
        try GameInstaller.synchronizePointerInput(in: app, settings: settings)
        #expect(GameInstaller.infoPlist(app)?["UIApplicationSupportsIndirectInputEvents"] == nil)
        #expect(GameInstaller.infoPlist(app)?["MulgManagedDirectPointerInput"] == nil)
        #expect(try GameInstaller.pointerInputIsCurrent(in: app, settings: settings))
        let plist = app.appendingPathComponent("Info.plist")
        let native = try Data(contentsOf: plist)
        try GameInstaller.synchronizePointerInput(in: app, settings: settings)
        #expect(try Data(contentsOf: plist) == native)
    }

    @Test(arguments: [true, false]) func explicitAppPolicyIsNeverChanged(_ declared: Bool) throws {
        let app = try InstallerTests().makeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        var info = try #require(GameInstaller.infoPlist(app))
        info["UIApplicationSupportsIndirectInputEvents"] = declared
        let original = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        let plist = app.appendingPathComponent("Info.plist")
        try original.write(to: plist)
        try GameInstaller.synchronizePointerInput(in: app, settings: GameSettings())
        try GameInstaller.restorePointerInput(in: app)
        #expect(try Data(contentsOf: plist) == original)
    }

    @Test(arguments: PlayMode.allCases) func backendChangesRestoreOnlyManagedPolicy(_ mode: PlayMode) throws {
        let app = try InstallerTests().makeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        var settings = GameSettings()
        try GameInstaller.synchronizePointerInput(in: app, settings: settings)
        settings.mulg.controls.playMode = mode
        try GameInstaller.synchronizePointerInput(in: app, settings: settings)
        let info = try #require(GameInstaller.infoPlist(app))
        if mode == .touch {
            #expect(info["UIApplicationSupportsIndirectInputEvents"] as? Bool == false)
        } else {
            #expect(info["UIApplicationSupportsIndirectInputEvents"] == nil)
        }
        settings.keymapping = false
        try GameInstaller.synchronizePointerInput(in: app, settings: settings)
        #expect(GameInstaller.infoPlist(app)?["UIApplicationSupportsIndirectInputEvents"] == nil)
    }
}
#endif
