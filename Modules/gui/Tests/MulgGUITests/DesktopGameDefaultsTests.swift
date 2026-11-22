#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Testing
import MulgContracts
@testable import MulgGUI

@MainActor
@Suite("Desktop defaults migration")
struct DesktopGameDefaultsTests {
    @Test func migratesSavedAndInstalledGamesOnceAndKeepsLaterUserChoices() throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:home)}
        let paths=ContainerPaths(home:home),store=SettingsStore(paths:paths)
        let suite="test.desktop."+UUID().uuidString
        let defaults=try #require(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        defaults.set("batterySaver",forKey:"gui.defaultProfile")
        let id="com.test.saved",installed="com.test.installed"
        var old=GameSettings(bundleIdentifier:id)
        old.sensitivity=93;old.mulg.display.frameRateCap=30
        old.mulg.display.batterySaverOnBattery=true
        old.mulg.graphics.metalFX.enabled=true;old.mulg.graphics.forceRenderResolution=false
        try store.save(old)
        let path=paths.settingsFile(for:id)
        var tree=try #require(try PropertyListSerialization.propertyList(from:Data(contentsOf:path),format:nil) as? [String:Any])
        tree["futureExtension"]=["keep":true]
        try PropertyListSerialization.data(fromPropertyList:tree,format:.xml,options:0).write(to:path)
        try FileManager.default.createDirectory(at:paths.applicationsDirectory.appendingPathComponent(installed+".app"),withIntermediateDirectories:true)
        let migrated=try DesktopGameDefaults.migrate(paths:paths,defaults:defaults)
        #expect(Set(migrated)==Set([id,installed]))
        #expect(defaults.string(forKey:"gui.defaultProfile")==nil)
        let loaded=store.load(bundleIdentifier:id).settings
        #expect(loaded.sensitivity==93 && loaded.mulg.display.frameRateCap==120)
        #expect(!loaded.mulg.display.batterySaverOnBattery && !loaded.mulg.graphics.metalFX.enabled)
        #expect(loaded.resolution==ResolutionMode.display.rawValue && loaded.mulg.graphics.forceRenderResolution)
        let preserved=try #require(try PropertyListSerialization.propertyList(from:Data(contentsOf:path),format:nil) as? [String:Any])
        #expect((preserved["futureExtension"] as? [String:Bool])?["keep"]==true)
        var later=loaded;later.mulg.display.frameRateCap=45;later.mulg.graphics.forceRenderResolution=false
        try store.save(later,basedOn:loaded)
        defaults.set("balanced",forKey:"gui.defaultProfile")
        #expect(try DesktopGameDefaults.migrate(paths:paths,defaults:defaults).isEmpty)
        #expect(store.load(bundleIdentifier:id).settings.mulg.display.frameRateCap==45 && !store.load(bundleIdentifier:id).settings.mulg.graphics.forceRenderResolution)
        #expect(defaults.string(forKey:"gui.defaultProfile")=="balanced")
    }

    @Test func unreadableSettingsRemainUntouchedAndRetryAfterRepair() throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:home)}
        let paths=ContainerPaths(home:home),store=SettingsStore(paths:paths)
        let suite="test.desktop."+UUID().uuidString
        let defaults=try #require(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        let bad="com.test.bad",good="com.test.good"
        try store.save(GameSettings(bundleIdentifier:good))
        let corrupt=Data("broken preferences".utf8)
        try corrupt.write(to:paths.settingsFile(for:bad))
        #expect(throws:(any Error).self) {try DesktopGameDefaults.migrate(paths:paths,defaults:defaults)}
        #expect(try Data(contentsOf:paths.settingsFile(for:bad))==corrupt)
        #expect(store.load(bundleIdentifier:good).settings.mulg.display.frameRateCap==120)
        try store.save(GameSettings(bundleIdentifier:bad))
        #expect(try DesktopGameDefaults.migrate(paths:paths,defaults:defaults)==[bad])
    }

    @Test func sparseFilesPersistThePolicyWithoutChangingFutureControlValues() throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:home)}
        let paths=ContainerPaths(home:home),store=SettingsStore(paths:paths),id="com.test.sparse"
        let suite="test.desktop."+UUID().uuidString
        let defaults=try #require(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        let original: [String:Any] = ["sensitivity":77,"mulg":["controls":["playMode":"future-mode","futureFlag":true]]]
        _ = try store.saveLegacy(PropertyListSerialization.data(fromPropertyList:original,format:.xml,options:0),basedOn:nil,bundleIdentifier:id)
        _ = try DesktopGameDefaults.migrate(paths:paths,defaults:defaults)
        let tree=try #require(try PropertyListSerialization.propertyList(from:Data(contentsOf:paths.settingsFile(for:id)),format:nil) as? [String:Any])
        let mulg=try #require(tree["mulg"] as? [String:Any])
        #expect((mulg["display"] as? [String:Any])?["frameRateCap"] as? Int == 120)
        #expect((mulg["controls"] as? [String:Any])?["playMode"] as? String == "future-mode")
        #expect((mulg["controls"] as? [String:Any])?["futureFlag"] as? Bool == true)
        #expect(tree["sensitivity"] as? Int == 77)
    }
    @Test func futureInstallReceivesTheSamePolicy() throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:home)}
        let paths=ContainerPaths(home:home),actions=GameActions(paths:paths)
        try actions.applyPerformanceDefaults(for:"com.test.new")
        let settings=SettingsStore(paths:paths).load(bundleIdentifier:"com.test.new").settings
        #expect(settings.resolution==ResolutionMode.display.rawValue && settings.mulg.display.frameRateCap==120)
        #expect(!settings.mulg.display.backgroundThrottle && !settings.mulg.display.batterySaverOnBattery && !settings.mulg.display.thermalGuard)
        #expect(!settings.mulg.graphics.metalFX.enabled && !settings.mulg.graphics.metalFX.automatic)
        #expect(settings.mulg.graphics.forceRenderResolution && settings.mulg.graphics.fullResolution)
    }
}
#endif