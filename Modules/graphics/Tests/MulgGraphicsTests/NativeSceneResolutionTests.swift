import Foundation
import MulgContracts
import MulgGraphicsHooks
import Testing
@testable import MulgGraphics

@Suite("Native scene resolution") @MainActor
struct NativeSceneResolutionTests {
    final class Adapter: NativeSceneResolutionAdapter {
        var availability: MulgNativeSceneState = .unsupported
        var ownsEngineValues = false
        var restoreAllowed = true
        var requests: [Bool] = []
        var diagnostics: [String: Any] { [:] }
        func probe() -> MulgNativeSceneState { availability }
        func apply(_ enabled: Bool) -> MulgNativeSceneState {
            requests.append(enabled)
            if enabled { ownsEngineValues = true; return .applied }
            if !restoreAllowed { return .failed }
            ownsEngineValues = false
            return .restored
        }
    }

    @Test func settingIsExplicitlyOptInAndRoundTrips() throws {
        var settings = try JSONDecoder().decode(GraphicsSettings.self, from: Data("{}".utf8))
        #expect(!settings.nativeSceneResolution)
        settings.nativeSceneResolution = true
        #expect(try JSONDecoder().decode(GraphicsSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func unsupportedLeavesLegacyAloneAndOffRestoresASelectedAdapter() {
        let unknown = Adapter(), supported = Adapter()
        let controller = NativeSceneResolution(adapters: [unknown, supported])
        var legacyReleases = 0
        func update(_ on: Bool, metalFX: Bool = false) {
            controller.reconcile(requested: on, outputForced: true, metalFXActive: metalFX) { legacyReleases += 1 }
        }
        update(true)
        #expect(!controller.managesScene && legacyReleases == 0 && unknown.requests.isEmpty)
        #expect(controller.report["status"] as? String == "unsupported")
        supported.availability = .ready
        update(true, metalFX: true)
        #expect(supported.requests.isEmpty && legacyReleases == 0)
        update(true)
        #expect(controller.managesScene && legacyReleases == 1 && supported.requests == [true])
        #expect(controller.report["nativeSceneVerified"] as? Bool == false)
        update(false)
        #expect(supported.requests == [true, false] && !controller.managesScene)
        #expect(controller.report["status"] as? String == "off")
    }

    @Test func failedRestorationDoesNotReleaseOwnershipOrRetryForever() {
        let adapter = Adapter()
        adapter.availability = .ready
        let controller = NativeSceneResolution(adapters: [adapter])
        controller.reconcile(requested: true, outputForced: true, metalFXActive: false) {}
        adapter.restoreAllowed = false
        for _ in 0..<5 { controller.reconcile(requested: false, outputForced: false, metalFXActive: false) {} }
        #expect(adapter.requests == [true, false, false, false])
        #expect(controller.managesScene && !controller.needsRestoreRetry)
        #expect(controller.report["status"] as? String == "restartToRestore")
    }

    #if os(macOS) && !targetEnvironment(macCatalyst)
    @Test func productionAdapterUsesOnlyVerifiedReversibleEngineCalls() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let source = root.appendingPathComponent("Modules/graphics/Sources/MulgGraphicsHooks")
        let binary = work.appendingPathComponent("native-scene-fixture")
        func run(_ executable: String, _ arguments: [String]) throws {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0, Comment(rawValue: String(decoding: output, as: UTF8.self)))
        }
        for name in ["NativeSceneResolution.m", "MobilePresetSceneResolution.m", "UnityDisplayAdoption.m", "GenshinSceneResolution.m"] {
            let fixture = root.appendingPathComponent("Modules/graphics/Tests/HookFixtures/\(name)")
            try run("/usr/bin/xcrun", ["clang", "-fobjc-arc", "-fblocks", "-I", source.path,
                "-I", root.appendingPathComponent("Modules/engine/Sources/MulgEngineHooks/include").path,
                "-I", source.appendingPathComponent("include").path, fixture.path,
                "-framework", "Foundation", "-framework", "CoreGraphics", "-o", binary.path])
            try run(binary.path, [])
        }
    }
    #endif
}
