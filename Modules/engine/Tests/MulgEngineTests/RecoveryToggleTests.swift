import Foundation
import Testing
import MulgContracts
@testable import MulgEngine

@Suite("Per-game recovery switch")
struct RecoveryToggleTests {
    @Test func interruptedStartupWithoutAttributionDoesNotDisableControls() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let safe = SafeMode(marker: folder.appendingPathComponent("launch"))
        let settings = GameSettings(bundleIdentifier: "test.foreign.startup")
        _ = safe.beginLaunch(settings: settings)
        safe.stage(.preparing, module: .controls)
        #expect(safe.interruptedModule() == .controls)
        #expect(SafeMode.moduleToDisable(blamedModule: nil, settings: settings) == nil)
        // Missing or foreign reports still trigger temporary recovery, never a saved disable.
        for _ in 0..<4 { _ = safe.beginLaunch(settings: settings) }
        #expect(SafeMode(marker: safe.marker).beginLaunch(settings: settings).isMinimal)
        #expect(settings.mulg.engine.isModuleEnabled(.controls))
    }

    @Test func attributedRecoveryHonorsEssentialAndExplicitSwitches() {
        var settings = GameSettings()
        #expect(SafeMode.moduleToDisable(blamedModule: .controls, settings: settings) == .controls)
        #expect(SafeMode.moduleToDisable(blamedModule: .engine, settings: settings) == nil)
        #expect(SafeMode.moduleToDisable(blamedModule: .library, settings: settings) == nil)
        settings.mulg.engine.disabledModules = ["controls"]
        #expect(SafeMode.moduleToDisable(blamedModule: .controls, settings: settings) == nil)
        settings.mulg.engine.disabledModules = []
        settings.mulg.engine.automaticRecovery = false
        #expect(SafeMode.moduleToDisable(blamedModule: .controls, settings: settings) == nil)
    }
    @Test func unavailableArchiveDoesNotStopRecoveryJournal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("launch")
        let first = SafeMode(marker: marker)
        _ = first.beginLaunch()
        first.stage(.preparing, module: .graphics)
        // A directory at the archive path makes the optional atomic backup fail.
        try FileManager.default.createDirectory(at: first.previousRecord, withIntermediateDirectories: true)
        let second = SafeMode(marker: marker)
        #expect(second.beginLaunch() == .normal)
        #expect(second.record()?.unfinishedLaunches == 2)
        #expect(second.record()?.stage == .boot)
        second.stage(.waitingForScene)
        #expect(second.record()?.stage == .waitingForScene)
        #expect(second.interruptedModule() == nil)
        #expect(SafeMode(marker: marker).beginLaunch().isSafe)
        _ = SafeMode(marker: marker).beginLaunch()
        #expect(SafeMode(marker: marker).beginLaunch().isMinimal)
    }

    @Test func disabledRecoveryHonorsPersistedSettingDespiteRepeatedFailures() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = ContainerPaths(home: home), id = "audit.recovery"
        let marker = paths.safeModeMarker(for: id)
        for _ in 0..<4 { _ = SafeMode(marker: marker).beginLaunch() }
        #expect(LaunchEnvironment.needsMinimalRecovery(marker: marker))
        var settings = GameSettings(bundleIdentifier: id)
        settings.mulg.engine.automaticRecovery = false
        try SettingsStore(paths: paths).save(settings)
        let saved = SettingsStore(paths: paths).load(bundleIdentifier: id).settings
        #expect(!saved.mulg.engine.automaticRecovery)
        #expect(!LaunchEnvironment.needsMinimalRecovery(marker: marker, settings: saved))
        #expect(SafeMode(marker: marker).beginLaunch(settings: saved) == .normal)
        settings.mulg.engine.automaticRecovery = true
        #expect(SafeMode(marker: marker).beginLaunch(settings: settings).isMinimal)
        // A different game retains its own default, regardless of this switch.
        #expect(SettingsStore(paths: paths).load(bundleIdentifier: "audit.other").settings.mulg.engine.automaticRecovery)
    }
    @Test func launchEndingDuringAModuleStartNamesThatModule() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("launch")
        let first = SafeMode(marker: marker)
        _ = first.beginLaunch()
        #expect(SafeMode(marker: marker).interruptedModule() == nil)  // ended in .boot: no module to name
        first.stage(.preparing, module: .graphics)
        #expect(SafeMode(marker: marker).interruptedModule() == .graphics)
        first.stage(.activating, module: .controls)
        #expect(SafeMode(marker: marker).interruptedModule() == .controls)
        // Once start-up moves past the modules, an ending is not blamed on the last one.
        for stage in [SafeMode.Stage.waitingForScene, .running, .healthy, .closing] {
            first.stage(stage, module: nil)
            #expect(SafeMode(marker: marker).interruptedModule() == nil)
        }
        try? FileManager.default.removeItem(at: marker)
        #expect(SafeMode(marker: marker).interruptedModule() == nil)
    }
    @Test func healthyOldMarkerRestoresFullRuntimeOnNextLaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let safe = SafeMode(marker: folder.appendingPathComponent("launch"))
        for _ in 0..<5 { _ = safe.beginLaunch() }
        safe.stage(.healthy)
        #expect(safe.record()?.unfinishedLaunches == 0)
        #expect(!LaunchEnvironment.needsMinimalRecovery(marker: safe.marker))
        // Preserve compatibility with healthy journals produced by the old runtime.
        var record = try #require(safe.record()); record.unfinishedLaunches = 5
        try JSONEncoder().encode(record).write(to: safe.marker)
        #expect(!LaunchEnvironment.needsMinimalRecovery(marker: safe.marker))
        #expect(SafeMode(marker: safe.marker).beginLaunch() == .normal)
    }
}
