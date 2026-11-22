import QuartzCore
import Testing
import MulgGraphicsHooks
import MulgContracts
import MulgEngine
@testable import MulgGraphics
#if os(macOS) && !targetEnvironment(macCatalyst)
import MulgBridgeAppKit
#endif

private final class PacingDrawable: NSObject { @objc let layer = CAMetalLayer() }

@Suite("Live layer restoration", .serialized)
struct LiveLayerSettingsTests {
    @Test @MainActor func surfaceRecoveryPreservesPreferencesAndFatalBlockers() {
        var settings = GameSettings()
        settings.mulg.graphics.metalFX.enabled = true
        let paths = ContainerPaths(home: FileManager.default.temporaryDirectory)
        let context = ModuleContext(bundleIdentifier: "graphics.recovery", paths: paths,
            settingsStore: SettingsStore(paths: paths), settings: settings, launch: .normal, bridge: nil)
        let module = GraphicsModule(), first = CAMetalLayer(), second = CAMetalLayer(), third = CAMetalLayer()
        defer { mulg_graphics_set_main_layer(nil); mulg_graphics_configure(MulgGraphicsConfig()) }
        module.mainLayerChanged(to: first, context: context)
        module.block(.notSupported("temporary drawable shortage"), context: context, recoverable: true)
        module.mainLayerChanged(to: first, context: context)
        #expect(module.blocker != nil && !module.metalFXEnabled)
        module.mainLayerChanged(to: second, context: context)
        #expect(module.blocker == nil && module.metalFXEnabled)
        #expect(context.settings == settings)
        module.block(.notSupported("GPU execution error"), context: context)
        module.mainLayerChanged(to: third, context: context)
        #expect(module.blocker == .notSupported("GPU execution error") && !module.metalFXEnabled)
        #expect(context.settings == settings)
    }

    @Test func unrelatedConfigurationPreservesBothFractionalAndVsyncFreeCaps() {
        let drawable = PacingDrawable()
        mulg_graphics_set_main_layer(drawable.layer)
        var config = MulgGraphicsConfig()
        config.refreshesPerFrame = 1.5; config.refreshPeriod = 1.0 / 60
        mulg_graphics_configure(config)
        defer { mulg_graphics_set_main_layer(nil); mulg_graphics_configure(MulgGraphicsConfig()) }
        var holds: [Double] = []
        for i in 0..<4 {
            config.reportPresentTimes = Int32(i % 2)
            mulg_graphics_configure(config)
            holds.append(mulg_graphics_pace(drawable, 0, false))
        }
        #expect(holds[0] == holds[2] && holds[1] == holds[3] && holds[1] > holds[0] * 2)
        config.variableRefresh = 1; config.vsyncDisabled = 1
        mulg_graphics_configure(config)
        let before = CACurrentMediaTime()
        for i in 0..<5 {
            config.lowLatency = Int32(i % 2)
            mulg_graphics_configure(config)
            _ = mulg_graphics_pace(drawable, 0, false)
        }
        #expect(CACurrentMediaTime() - before >= 0.09)
    }
    #if os(macOS) && !targetEnvironment(macCatalyst)
    @Test @MainActor func layerSwitchAndDisableRestoreEachOriginalVsyncValue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root), store = SettingsStore(paths: paths), id = "audit.vsync"
        var settings = GameSettings(bundleIdentifier: id)
        settings.mulg.graphics.vsyncOff = true
        let launch = SafeMode(paths: paths, bundleIdentifier: id).beginLaunch(settings: settings)
        let context = ModuleContext(bundleIdentifier: id, paths: paths, settingsStore: store, settings: settings,
                                    launch: launch, bridge: AppKitBridge())
        let module = GraphicsModule(), first = CAMetalLayer(), second = CAMetalLayer()
        first.displaySyncEnabled = false
        second.displaySyncEnabled = true
        module.mainLayerChanged(to: first, context: context)
        module.mainLayerChanged(to: second, context: context)
        #expect(!first.displaySyncEnabled && !second.displaySyncEnabled)
        context.updateSettings { $0.mulg.graphics.vsyncOff = false }
        module.settingsChanged(from: settings, context: context)
        #expect(!first.displaySyncEnabled && second.displaySyncEnabled)
        // A new override captures the game's latest preference instead of an old snapshot.
        second.displaySyncEnabled = false
        settings = context.settings
        context.updateSettings { $0.mulg.graphics.vsyncOff = true }
        module.settingsChanged(from: settings, context: context)
        settings = context.settings
        context.updateSettings { $0.mulg.graphics.vsyncOff = false }
        module.settingsChanged(from: settings, context: context)
        #expect(!second.displaySyncEnabled)
    }
    #endif
    @Test func vsyncOffActuallyWaitsWithoutChangingGamePresentationArguments() {
        let drawable = PacingDrawable()
        mulg_graphics_set_main_layer(drawable.layer)
        defer { mulg_graphics_set_main_layer(nil) }
        var config = MulgGraphicsConfig()
        config.renderPercent = 100
        config.refreshesPerFrame = 0.5 // 120 FPS on 60 Hz, independent of scanout.
        config.refreshPeriod = 1.0 / 60
        config.variableRefresh = 1
        config.vsyncDisabled = 1
        mulg_graphics_configure(config)
        defer { mulg_graphics_configure(MulgGraphicsConfig()) }
        let before = CACurrentMediaTime()
        for _ in 0..<5 { #expect(mulg_graphics_pace(drawable, 0.001, false) == 0.001) }
        #expect(CACurrentMediaTime() - before >= 4.0 / 120 - 0.002)
        config.refreshesPerFrame = 0
        mulg_graphics_configure(config)
        #expect(mulg_graphics_pace(drawable, 42, true) == 42)
    }
    @Test func pacingRebasesAndDropsOldConfigurationDeadlines() {
        let drawable = PacingDrawable()
        mulg_graphics_set_main_layer(drawable.layer)
        defer { mulg_graphics_set_main_layer(nil) }
        var config = MulgGraphicsConfig()
        config.renderPercent = 100
        config.refreshesPerFrame = 2
        config.refreshPeriod = 1.0 / 120
        mulg_graphics_configure(config)
        defer { mulg_graphics_configure(MulgGraphicsConfig()) }
        let before = CACurrentMediaTime()
        #expect(mulg_graphics_pace(drawable, 0, true) >= before)
        _ = mulg_graphics_pace(drawable, before + 5, true)
        config.refreshesPerFrame = 3
        mulg_graphics_configure(config)
        #expect(mulg_graphics_pace(drawable, 0, true) < CACurrentMediaTime() + 0.1)
    }

    @Test func secondaryPresentationArgumentsAreUntouchedOnEveryQueue() async {
        let main = PacingDrawable(), secondary = PacingDrawable()
        mulg_graphics_set_main_layer(main.layer)
        var config = MulgGraphicsConfig()
        config.refreshesPerFrame = 2
        config.refreshPeriod = 1.0 / 60
        config.vsyncDisabled = 1
        config.variableRefresh = 1
        mulg_graphics_configure(config)
        defer { mulg_graphics_set_main_layer(nil); mulg_graphics_configure(MulgGraphicsConfig()) }
        let before = CACurrentMediaTime()
        for _ in 0..<4 { #expect(mulg_graphics_pace(secondary, 42, false) == 42) }
        #expect(CACurrentMediaTime() - before < 0.05)
        // Secondary drawables on a different presenting queue remain untouched too.
        let ticks = await Task.detached {
            // Confine the drawable to its presenting queue.
            let drawable = PacingDrawable()
            #expect(mulg_graphics_pace(drawable, 42, true) == 42)
            return CACurrentMediaTime()
        }.value
        #expect(ticks > before)
        let start = CACurrentMediaTime()
        for _ in 0..<4 { _ = mulg_graphics_pace(main, 0, false) }
        #expect(CACurrentMediaTime() - start >= 0.09)
    }

    @Test func restoresGameValuesOnDisable() {
        let layer = CAMetalLayer()
        layer.maximumDrawableCount = 3
        layer.isOpaque = false
        var config = MulgGraphicsConfig()
        config.renderPercent = 100
        config.lowLatency = 1
        config.makeLayersOpaque = 1
        mulg_graphics_configure(config)
        mulg_graphics_set_main_layer(layer)
        defer { mulg_graphics_set_main_layer(nil); mulg_graphics_configure(MulgGraphicsConfig()) }
        mulg_graphics_apply_layer_config(layer)
        #expect(layer.maximumDrawableCount == 2 && layer.isOpaque)
        config.lowLatency = 0
        config.makeLayersOpaque = 0
        mulg_graphics_configure(config)
        mulg_graphics_apply_layer_config(layer)
        #expect(layer.maximumDrawableCount == 3 && !layer.isOpaque)
        // Re-enabling must capture the game's latest state, not an old launch-time value.
        layer.isOpaque = true
        config.makeLayersOpaque = 1
        mulg_graphics_configure(config)
        mulg_graphics_apply_layer_config(layer)
        config.makeLayersOpaque = 0
        mulg_graphics_configure(config)
        mulg_graphics_apply_layer_config(layer)
        #expect(layer.isOpaque)
    }

    @Test @MainActor func opacityFollowsOnlyTheSelectedFullscreenSurfaceAndRestoresOnRebinding() {
        let module = GraphicsModule(), first = CAMetalLayer(), second = CAMetalLayer()
        var settings = GameSettings()
        settings.mulg.graphics.fullScreenPerformanceMode = true
        first.isOpaque = false; second.isOpaque = false
        defer { mulg_graphics_set_main_layer(nil); mulg_graphics_configure(MulgGraphicsConfig()) }
        module.applyConfig(settings) // No fullscreen bridge: a windowed game.
        mulg_graphics_set_main_layer(first)
        #expect(!first.isOpaque)
        var config = mulg_graphics_current_config()
        config.makeLayersOpaque = 1 // Simulates a fullscreen transition from the bridge.
        mulg_graphics_configure(config)
        mulg_graphics_apply_layer_config(first)
        mulg_graphics_apply_layer_config(second)
        #expect(first.isOpaque && !second.isOpaque)
        mulg_graphics_set_main_layer(second)
        #expect(!first.isOpaque && second.isOpaque)
        module.applyConfig(settings) // Fullscreen exit restores the selected layer immediately.
        mulg_graphics_apply_layer_config(second)
        #expect(!first.isOpaque && !second.isOpaque)
    }

    @Test @MainActor func failedHotkeySaveDoesNotEnableMetalFX() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root), id = "graphics.failed-write"
        try FileManager.default.createDirectory(at: paths.appSettingsDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("blocks directory".utf8).write(to: paths.appSettingsDirectory)
        let context = ModuleContext(bundleIdentifier: id, paths: paths, settingsStore: SettingsStore(paths: paths),
                                    settings: GameSettings(bundleIdentifier: id), launch: .normal, bridge: nil)
        let module = GraphicsModule()
        module.setMetalFX(enabled: true, context: context)
        #expect(!module.metalFXEnabled && !context.settings.mulg.graphics.metalFX.enabled)
    }
}
