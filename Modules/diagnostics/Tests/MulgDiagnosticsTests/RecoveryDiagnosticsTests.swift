import Foundation
import MulgContracts
import MulgEngine
import Testing
@testable import MulgDiagnostics

@Suite("Recovery diagnostic startup", .serialized) @MainActor
struct RecoveryDiagnosticsTests {
    @Test func minimalStartupKeepsPreferencesAndRecoveryRecordWithoutStartingDebugger() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root), id = "recovery.diagnostics"
        var settings = GameSettings(bundleIdentifier: id)
        settings.mulg.diagnostics.debugger = true
        settings.mulg.diagnostics.debugShaders = true
        settings.mulg.diagnostics.debugCPU = true
        settings.mulg.diagnostics.debugGraphics = true
        settings.metalHUD = true
        let store = SettingsStore(paths: paths)
        try store.save(settings)
        for _ in 0..<4 { _ = SafeMode(paths: paths, bundleIdentifier: id).beginLaunch(settings: settings) }
        let recovery = SafeMode(paths: paths, bundleIdentifier: id)
        let launch = recovery.beginLaunch(settings: settings)
        #expect(launch.isMinimal && recovery.record()?.stage == .boot)
        DiagnosticsModule.startDebugger(settings: settings, paths: paths, bundleIdentifier: id,
                                        minimalRecovery: launch.isMinimal)
        #expect(!FileManager.default.fileExists(atPath: paths.diagnosticsDirectory(for: id).appendingPathComponent(Debugger.fileName).path))
        let keys = ["MTL_DEBUG_LAYER", "MTL_SHADER_VALIDATION", "MTL_HUD_ENABLED"]
        let before = keys.map { key in getenv(key).map { String(cString: $0) } }
        defer {
            for (key, value) in zip(keys, before) {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        keys.forEach { unsetenv($0) }
        DiagnosticsModule.setMetalEnvironment(settings, minimalRecovery: true)
        #expect(keys.allSatisfy { getenv($0) == nil })
        #expect(settings.mulg.diagnostics.writesCrashReports)
        #expect(store.load(bundleIdentifier: id).settings == settings)
        DiagnosticsModule.setMetalEnvironment(settings)
        #expect(keys.allSatisfy { getenv($0) == nil }) // never set, whatever old settings say
    }
}
