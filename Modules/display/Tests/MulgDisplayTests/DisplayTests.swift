import Foundation
import Testing
import MulgContracts
import MulgDisplayHooks
import MulgEngine
@testable import MulgDisplay

@Suite("Renderer cap publication") @MainActor
struct RendererCapPublicationTests {
    @Test func sameRefreshDisplayChangeRefreshesHDRWithoutPublishingAnotherCap() {
        var settings = GameSettings()
        settings.mulg.display.reportHDRHeadroom = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root)
        let context = ModuleContext(bundleIdentifier: "display.hdr", paths: paths,
            settingsStore: SettingsStore(paths: paths), settings: settings, launch: .normal, bridge: nil)
        let display = DisplayModule()
        display.reconfigure(context)
        display.publishFrameLimit(context)
        var published = 0
        context.events.subscribe(FrameLimitChanged.self) { _ in published += 1 }
        var config = mulg_display_current_config()
        config.edrHeadroom = 4
        mulg_display_configure(config)
        display.displayChanged(to: 60, context: context)
        #expect(mulg_display_current_config().edrHeadroom == 1)
        #expect(published == 0 && display.displayMaximum == 60)
        let old = context.settings
        #expect(context.updateSettings { $0.mulg.display.reportHDRHeadroom = false })
        display.settingsChanged(from: old, context: context)
        #expect(mulg_display_current_config().edrHeadroom == 0)
    }
    @Test func presentsReceiveTheEffectiveCeilingWithoutCappingUncapOnly() {
        for (refresh, fixed, below, expected) in [(120, 0, true, 116), (60, 120, false, 120),
                                                (120, 45, true, 45), (120, 0, false, 0)] {
            var settings = GameSettings()
            settings.mulg.display.frameRateCap = fixed
            settings.mulg.display.frameCapBelowRefresh = below
            settings.mulg.display.uncapFrameRate = true
            let paths = ContainerPaths(home: FileManager.default.temporaryDirectory)
            let context = ModuleContext(bundleIdentifier: "cap.test", paths: paths,
                settingsStore: SettingsStore(paths: paths), settings: settings, launch: .normal, bridge: nil)
            var published: [Int] = []
            context.events.subscribe(FrameLimitChanged.self) { published.append($0.framesPerSecond) }
            let display = DisplayModule()
            display.reconfigure(context)
            display.displayChanged(to: refresh, context: context)
            #expect(published.last == expected)
            #expect(display.throttleRate(visible: true, context: context) == 0)
        }
    }
}

@Suite("ScreenGeometry")
struct ScreenGeometryTests {
    @Test("Resolution 0 means the game sees the real screen")
    func off() {
        var settings = GameSettings()
        settings.resolution = 0
        #expect(ScreenGeometry(settings: settings).mode == .off)
    }

    @Test("Every resolution follows the real window, seeded with the window size and scaler; Off stays native")
    func followsWindow() {
        var settings = GameSettings()
        settings.resolution = 5
        settings.windowWidth = 2560
        settings.windowHeight = 1440
        settings.customScaler = 1.5
        #expect(ScreenGeometry(settings: settings) == ScreenGeometry(mode: .resizable, width: 2560, height: 1440, scale: 1.5))
        for mode in ResolutionMode.allCases where mode != .off {
            settings.resolution = mode.rawValue
            #expect(ScreenGeometry(settings: settings).mode == .resizable)
        }
        // Automatic: the window's real scale (0 = ask the window), whatever the render scale says.
        settings.resolution = ResolutionMode.auto.rawValue
        #expect(ScreenGeometry(settings: settings).scale == 0)
    }

    @Test("Retina off reports one pixel per point without changing the selected geometry")
    func retinaScaleAcrossResolutionModes() {
        var settings = GameSettings()
        settings.windowWidth = 1200; settings.windowHeight = 800; settings.customScaler = 2
        for mode in ResolutionMode.allCases {
            settings.resolution = mode.rawValue
            settings.mulg.display.retina = true
            let on = ScreenGeometry(settings: settings)
            settings.mulg.display.retina = false
            let off = ScreenGeometry(settings: settings)
            #expect(off.scale == 1)
            #expect(off.mode == on.mode && off.width == on.width && off.height == on.height)
            settings.mulg.display.retina = true
            #expect(ScreenGeometry(settings: settings) == on)
        }
    }

    @Test("The inverse fix swaps width and height, as upstream did")
    func inverted() {
        var settings = GameSettings()
        settings.resolution = 2
        settings.inverseScreenValues = true
        settings.windowWidth = 1920
        settings.windowHeight = 1080
        let geometry = ScreenGeometry(settings: settings)
        #expect(geometry.mode == .adaptiveInverted)
        #expect(geometry.width == 1080)
        #expect(geometry.height == 1920)
    }

    @Test("Resolution 6 is the resizable window")
    func resizable() {
        var settings = GameSettings()
        settings.resolution = 6
        #expect(ScreenGeometry(settings: settings).mode == .resizable)
    }
}

@Suite("FrameRatePolicy")
struct FrameRatePolicyTests {
    @Test func rendererCeilingsKeepAboveRefreshCapsAndHonorBelowRefresh() {
        var display = DisplaySettings()
        display.frameRateCap = 120
        #expect(FrameRatePolicy(displayMaximum: 60, settings: display).presentCap == 120)
        display.frameRateCap = 0; display.frameCapBelowRefresh = true
        #expect(FrameRatePolicy(displayMaximum: 120, settings: display).presentCap == 116)
        display.frameRateCap = 45
        #expect(FrameRatePolicy(displayMaximum: 120, settings: display).presentCap == 45)
        display.frameRateCap = 0; display.frameCapBelowRefresh = false
        display.uncapFrameRate = true
        #expect(FrameRatePolicy(displayMaximum: 120, settings: display).presentCap == 0)
    }
    @Test("The iPad capability stays 120 Hz on a 60/75 Hz Mac display; opt-out restores native reporting")
    func proMotionCapabilityIsIndependentOfPresentation() {
        var display = DisplaySettings()
        display.reportProMotion = true
        display.uncapFrameRate = true
        #expect(FrameRatePolicy(displayMaximum: 120, settings: display).reportedMaximum == 120)
        #expect(FrameRatePolicy(displayMaximum: 144, settings: display).reportedMaximum == 120)
        let sixty = FrameRatePolicy(displayMaximum: 60, settings: display)
        #expect(sixty.reportedMaximum == 120)
        #expect(sixty.proMotionUnavailable)
        let seventyFive = FrameRatePolicy(displayMaximum: 75, settings: display)
        #expect(seventyFive.reportedMaximum == 120 && seventyFive.proMotionUnavailable)
        #expect(seventyFive.target == 75)
        display.reportProMotion = false
        #expect(FrameRatePolicy(displayMaximum: 75, settings: display).reportedMaximum == 0)
    }

    @Test("Uncap targets the display rate; cap-below-refresh targets slightly less")
    func targets() {
        var display = DisplaySettings()
        display.uncapFrameRate = true
        #expect(FrameRatePolicy(displayMaximum: 120, settings: display).target == 120)
        display.frameCapBelowRefresh = true
        #expect(FrameRatePolicy(displayMaximum: 120, settings: display).target == 116)
        #expect(FrameRatePolicy.capTarget(forDisplayMaximum: 144) == 140)
        #expect(FrameRatePolicy.capTarget(forDisplayMaximum: 60) == 58)
    }

    @Test("Uncapping does nothing on a 60 Hz display")
    func noUncapAtSixty() {
        var display = DisplaySettings()
        display.uncapFrameRate = true
        display.frameRateCap = 0 // Exercise uncapping independently of the default 120 FPS ceiling.
        let policy = FrameRatePolicy(displayMaximum: 60, settings: display)
        #expect(!policy.uncap)
        #expect(policy.target == 0)
    }

    @Test("A fixed cap and the battery saver cap are ceilings (§7)")
    func caps() {
        var display = DisplaySettings()
        display.uncapFrameRate = true
        display.batterySaverOnBattery = true
        display.batteryFrameRateCap = 30
        #expect(FrameRatePolicy(displayMaximum: 120, settings: display, onBattery: false).target == 120)
        let battery = FrameRatePolicy(displayMaximum: 120, settings: display, onBattery: true)
        #expect(battery.capAtTarget && battery.target == 30)

        display.frameRateCap = 60
        #expect(FrameRatePolicy(displayMaximum: 120, settings: display, onBattery: false).target == 60)
        #expect(FrameRatePolicy(displayMaximum: 120, settings: display, onBattery: true).target == 30)
        display.uncapFrameRate = false
        #expect(FrameRatePolicy(displayMaximum: 48, settings: display).target == 48)
    }

    @Test("The thermal guard caps only while hot, and only when on (§13.1)")
    func thermalGuard() {
        var display = DisplaySettings()
        display.uncapFrameRate = true
        #expect(!display.thermalGuard) // Off for new games; on below.
        display.thermalGuard = true
        #expect(FrameRatePolicy(displayMaximum: 120, settings: display, hot: false).target == 120)
        let hot = FrameRatePolicy(displayMaximum: 120, settings: display, hot: true)
        #expect(hot.capAtTarget && hot.target == 60)
        display.batterySaverOnBattery = true
        display.batteryFrameRateCap = 30
        #expect(FrameRatePolicy(displayMaximum: 120, settings: display, onBattery: true, hot: true).target == 30)
        display.thermalGuard = false
        #expect(FrameRatePolicy(displayMaximum: 120, settings: display, hot: true).target == 120)
        #expect(DisplayModule.isHot(.serious) && DisplayModule.isHot(.critical) && !DisplayModule.isHot(.fair))
    }
}

@Suite("Frame-rate rules in the hooks")
struct FrameRateRuleTests {
    @Test("Any Unity player: a request below the target (or its default) asks for the target while uncapped")
    func unityPlayerRate() {
        let on = config(uncap: true, cap: false, target: 120), off = config(uncap: false, cap: false, target: 120)
        #expect(mulg_display_unity_player_rate(60, on) == 120)
        #expect(mulg_display_unity_player_rate(30, on) == 120)
        #expect(mulg_display_unity_player_rate(-1, on) == 120)
        #expect(mulg_display_unity_player_rate(144, on) == 144)
        #expect(mulg_display_unity_player_rate(60, off) == 60)
    }

    private func transform(_ config: MulgDisplayConfig, _ minimum: Float, _ maximum: Float, _ preferred: Float) -> [Float] {
        var values = (minimum, maximum, preferred)
        mulg_display_transform_range(config, &values.0, &values.1, &values.2)
        return [values.0, values.1, values.2]
    }

    private func config(uncap: Bool, cap: Bool, target: Int32) -> MulgDisplayConfig {
        var config = MulgDisplayConfig()
        config.uncapFrameRate = uncap ? 1 : 0
        config.capAtTarget = cap ? 1 : 0
        config.targetFramesPerSecond = target
        return config
    }

    @Test("A 60 FPS request is raised when uncapping")
    func uncap() {
        #expect(transform(config(uncap: true, cap: false, target: 120), 30, 60, 60) == [30, 120, 120])
    }

    @Test("A deliberate 30 FPS request is left alone")
    func thirtyStays() {
        #expect(transform(config(uncap: true, cap: false, target: 120), 30, 30, 30) == [30, 30, 30])
    }

    @Test("'As fast as possible' is capped below the refresh rate")
    func cap() {
        #expect(transform(config(uncap: false, cap: true, target: 116), 0, 0, 0) == [1, 116, 116])
        #expect(transform(config(uncap: false, cap: true, target: 116), 60, 120, 120) == [60, 116, 116])
    }

    @Test("With no target the request passes through unchanged")
    func passThrough() {
        #expect(transform(config(uncap: true, cap: true, target: 0), 0, 60, 60) == [0, 60, 60])
    }
}

@Suite("Display rotation")
struct DisplayRotationTests {
    @Test func normalisedIndex() {
        #expect(DisplayRotation.normalised(0) == 0)
        #expect(DisplayRotation.normalised(5) == 1)
        #expect(DisplayRotation.normalised(-1) == 3)
    }

    @Test("⇧⌘1–4, one per rotation, in one submenu")
    func menuCommands() {
        let commands = DisplayRotation.menuCommands()
        #expect(commands.map(\.key) == ["1", "2", "3", "4"])
        #expect(Set(commands.compactMap(\.submenu)) == ["Rotate display area"])
        #expect(commands.allSatisfy { $0.modifiers == [.command, .shift] })
    }
}

@Suite("Match device screen")
struct MatchDeviceScreenTests {
    @Test("The M5 13-inch screen is 1376 × 1032 points at 2×, whatever the window settings say")
    func matchesM5() {
        var settings = GameSettings()
        settings.resolution = ResolutionMode.matchDevice.rawValue
        settings.iosDeviceModel = "iPad17,3"
        settings.windowWidth = 1920
        settings.windowHeight = 1080
        settings.customScaler = 1.5
        let geometry = ScreenGeometry(settings: settings)
        #expect(geometry.mode == .resizable)
        #expect(geometry.width == 1376 && geometry.height == 1032)
        #expect(geometry.scale == 2)
    }

    @Test("The window size for the mode is the device's size in points")
    func windowSize() {
        let size = ResolutionCalculator.windowSize(mode: .matchDevice, aspect: .fourByThree, mainScreen: (0, 0),
                                                   screenHasNotch: false, custom: (0, 0))
        #expect(size.width == 1376 && size.height == 1032)
    }
}

@Suite("Native 4K and 5K")
struct NativeResolutionTests {
    @Test("4K and 5K draw every pixel at 2×, whatever the scaler says")
    func nativePixels() {
        for (mode, pixels) in [(ResolutionMode.native4K, (3840.0, 2160.0)), (.native5K, (5120.0, 2880.0))] {
            let size = ResolutionCalculator.windowSize(mode: mode, aspect: .fourByThree, mainScreen: (0, 0),
                                                       screenHasNotch: false, custom: (0, 0))
            var settings = GameSettings()
            settings.resolution = mode.rawValue
            settings.windowWidth = size.width
            settings.windowHeight = size.height
            settings.customScaler = 1.5
            let geometry = ScreenGeometry(settings: settings)
            #expect(geometry.width * geometry.scale == pixels.0 && geometry.height * geometry.scale == pixels.1)
        }
    }
}

@Suite("Activity while on screen") @MainActor
struct ActivityTests {
    @Test("Latency-critical while visible, display kept on only when asked, nothing while hidden")
    func options() {
        let busy: ProcessInfo.ActivityOptions = [.userInitiatedAllowingIdleSystemSleep, .latencyCritical]
        #expect(DisplayModule.activityOptions(visible: true, savingBattery: false, keepDisplayAwake: false) == busy)
        #expect(DisplayModule.activityOptions(visible: true, savingBattery: false, keepDisplayAwake: true)
            == busy.union(.idleDisplaySleepDisabled))
        #expect(DisplayModule.activityOptions(visible: true, savingBattery: true, keepDisplayAwake: true) == .idleDisplaySleepDisabled)
        #expect(DisplayModule.activityOptions(visible: false, savingBattery: false, keepDisplayAwake: true).isEmpty)
        #expect(DisplayModule.activityOptions(visible: false, savingBattery: true, keepDisplayAwake: false, downloading: true)
            == .userInitiatedAllowingIdleSystemSleep)
    }

    @Test("Only update-sized disk writes count as downloading while hidden")
    func downloading() {
        #expect(!DisplayModule.isBusy(bytesWritten: 200_000))
        #expect(DisplayModule.isBusy(bytesWritten: 6 << 20))
    }
}

#if os(macOS) && !targetEnvironment(macCatalyst)
@Suite("MTKView request restoration")
struct MetalKitRateLifetimeTests {
    @Test func livePolicyChangesKeepTheOriginalRequestAndDoNotRetainViews() throws {
        let module = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let hooks = module.appendingPathComponent("Sources/MulgDisplayHooks")
        let engine = module.deletingLastPathComponent().appendingPathComponent("engine/Sources/MulgEngineHooks")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("fixture.m"), executable = folder.appendingPathComponent("fixture")
        try Data("""
            #include <TargetConditionals.h>
            #import <Foundation/Foundation.h>
            #import <QuartzCore/QuartzCore.h>
            #import <MulgEngineHooks.h>
            #import <objc/runtime.h>
            #include "MulgDisplayInternal.h"
            #undef TARGET_OS_IPHONE
            #define TARGET_OS_IPHONE 1
            static Class fixture_lookup_class(const char *name);
            #define objc_getClass fixture_lookup_class
            #include "MulgFrameRateHooks.m"
            #undef objc_getClass
            #include <assert.h>
            @interface FixtureView : NSObject
            @property NSInteger preferredFramesPerSecond;
            @end
            @implementation FixtureView @end
            // A changed setter ABI must leave constructors alone as well.
            @interface FixtureBadMTKView : NSObject
            - (void)setPreferredFramesPerSecond:(int)fps;
            - (id)initWithFrame:(CGRect)frame device:(id)device;
            - (id)initWithCoder:(NSCoder *)coder;
            @end
            @implementation FixtureBadMTKView
            - (void)setPreferredFramesPerSecond:(int)fps {}
            - (id)initWithFrame:(CGRect)frame device:(id)device { return [super init]; }
            - (id)initWithCoder:(NSCoder *)coder { return [super init]; }
            @end
            static Class fixture_lookup_class(const char *name) {
                return strcmp(name, "MTKView") == 0 ? FixtureBadMTKView.class : objc_getClass(name);
            }
            int main(void) { @autoreleasepool {
                IMP constructor = class_getMethodImplementation(FixtureBadMTKView.class, @selector(initWithFrame:device:));
                MulgDisplayHook attempted = 0;
                assert(!(mulg_display_install_frame_rate_hooks(&attempted) & MulgDisplayHookMetalKitViewRate));
                assert(class_getMethodImplementation(FixtureBadMTKView.class, @selector(initWithFrame:device:)) == constructor);
                mulg_links = [NSHashTable weakObjectsHashTable];
                mulg_mtk_views = [NSHashTable weakObjectsHashTable];
                FixtureView *unhooked = [FixtureView new]; unhooked.preferredFramesPerSecond = 60;
                reapply_mtk_rate(unhooked); assert(unhooked.preferredFramesPerSecond == 60);
                previous_mtk_set_fps = class_getMethodImplementation(FixtureView.class, @selector(setPreferredFramesPerSecond:));
                __weak FixtureView *weakView;
                @autoreleasepool {
                    FixtureView *view = [FixtureView new]; weakView = view;
                    view.preferredFramesPerSecond = 60;
                    MulgDisplayConfig config = { .uncapFrameRate = 1, .targetFramesPerSecond = 120 };
                    mulg_display_configure(config); reapply_mtk_rate(view);
                    assert(view.preferredFramesPerSecond == 120);
                    config.uncapFrameRate = 0; mulg_display_configure(config);
                    mulg_display_set_background_throttle(0);
                    assert(view.preferredFramesPerSecond == 60);
                    mulg_mtk_set_fps(view, @selector(setPreferredFramesPerSecond:), 30);
                    config.uncapFrameRate = 1; config.capAtTarget = 1; config.targetFramesPerSecond = 25;
                    mulg_display_configure(config); mulg_display_set_background_throttle(0);
                    assert(view.preferredFramesPerSecond == 25);
                    mulg_display_set_background_throttle(10);
                    assert(view.preferredFramesPerSecond == 30);
                    config.capAtTarget = 0; config.targetFramesPerSecond = 144;
                    mulg_display_configure(config); mulg_display_set_background_throttle(0);
                    assert(view.preferredFramesPerSecond == 30);
                    mulg_mtk_set_fps(view, @selector(setPreferredFramesPerSecond:), 60);
                    assert(view.preferredFramesPerSecond == 144);
                    config.uncapFrameRate = 0; mulg_display_configure(config); mulg_display_set_background_throttle(0);
                    assert(view.preferredFramesPerSecond == 60);
                }
                assert(weakView == nil && mulg_mtk_views.allObjects.count == 0);
                return 0;
            } }
            """.utf8).write(to: source)
        func run(_ path: String, _ args: [String]) throws -> (Int32, String) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: path); process.arguments = args
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: output, as: UTF8.self))
        }
        let built = try run("/usr/bin/xcrun", ["clang", "-fobjc-arc", "-fblocks", "-I", hooks.path,
            "-I", hooks.appendingPathComponent("include").path, "-I", engine.appendingPathComponent("include").path,
            source.path, hooks.appendingPathComponent("MulgDisplayConfig.m").path,
            engine.appendingPathComponent("MulgSwizzle.m").path, engine.appendingPathComponent("MulgSleepThrottle.m").path,
            engine.appendingPathComponent("MulgImageHooks.m").path,
            "-framework", "Foundation", "-framework", "QuartzCore", "-o", executable.path])
        try #require(built.0 == 0, Comment(rawValue: built.1))
        let result = try run(executable.path, [])
        #expect(result.0 == 0, Comment(rawValue: result.1))
    }
}
#endif

@Suite("Resizable screen snapshot", .serialized)
struct WindowGeometryTests {
    @Test @MainActor func devicePresetTracksWindowChangesAtItsPixelScale() {
        let before = mulg_display_current_config()
        defer { mulg_display_configure(before); mulg_display_set_window_geometry(nil, .zero, 0) }
        var settings = GameSettings(); settings.resolution = ResolutionMode.matchDevice.rawValue
        let geometry = ScreenGeometry(settings: settings)
        var config = before
        config.screenMode = DisplayModule.hookMode(geometry.mode); config.scale = geometry.scale
        mulg_display_configure(config)
        let screen = NSObject()
        var bounds = CGRect.zero, scale = 0.0
        for size in [CGSize(width: 800, height: 600), CGSize(width: 1280, height: 720)] {
            mulg_display_set_window_geometry(screen, CGRect(origin: .zero, size: size), 1)
            #expect(mulg_display_window_geometry(screen, &bounds, &scale))
            #expect(bounds.size == size && scale == 2)
        }
    }

    @Test func publicationIsScreenScopedAndInvalidSnapshotsPassThrough() {
        let before = mulg_display_current_config()
        defer { mulg_display_configure(before); mulg_display_set_window_geometry(nil, .zero, 0) }
        var config = before; config.screenMode = .resizable; config.scale = 1.5
        mulg_display_configure(config)
        let screen = NSObject(), other = NSObject()
        var bounds = CGRect.zero, scale = 0.0
        #expect(!mulg_display_window_geometry(screen, &bounds, &scale))
        mulg_display_set_window_geometry(screen, CGRect(x: 20, y: 30, width: 900, height: 700), 2)
        #expect(mulg_display_window_geometry(screen, &bounds, &scale))
        #expect(bounds == CGRect(x: 0, y: 0, width: 900, height: 700) && scale == 1.5)
        #expect(!mulg_display_window_geometry(other, &bounds, &scale))
        config.scale = 0; mulg_display_configure(config)
        #expect(mulg_display_window_geometry(screen, &bounds, &scale) && scale == 2)
        mulg_display_set_window_geometry(screen, CGRect(x: 0, y: 0, width: CGFloat.nan, height: 1), 2)
        #expect(!mulg_display_window_geometry(screen, &bounds, &scale))
    }
}

@Suite("This display")
struct ThisDisplayTests {
    @Test("This display reports the monitor's real refresh rate and lifts the game's FPS limit to it")
    func followsMonitor() {
        var settings = GameSettings()
        settings.resolution = ResolutionMode.display.rawValue
        #expect(FrameRatePolicy(displayMaximum: 144, settings: DisplayModule.effectiveDisplay(settings)).target == 120)
        settings.mulg.display.frameRateCap = 0
        let display = DisplayModule.effectiveDisplay(settings)
        #expect(!display.reportProMotion && display.uncapFrameRate)
        let policy = FrameRatePolicy(displayMaximum: 144, settings: display)
        #expect(policy.reportedMaximum == 0 && policy.target == 144)
        settings.resolution = ResolutionMode.native4K.rawValue
        #expect(DisplayModule.effectiveDisplay(settings) == settings.mulg.display)
    }
}

@Suite("Frame-rate unlock: Unity")
struct UnityFrameRateUnlockTests {
    @Test("Unity's 60, 30 and default -1 are raised to the target; never lowered, nothing without a target")
    func raises() {
        #expect(mulg_display_unity_unlock_target(60, 120) == 120)
        #expect(mulg_display_unity_unlock_target(30, 120) == 120)
        #expect(mulg_display_unity_unlock_target(-1, 144) == 144)
        #expect(mulg_display_unity_unlock_target(120, 120) == 0)
        #expect(mulg_display_unity_unlock_target(240, 120) == 0)
        #expect(mulg_display_unity_unlock_target(60, 60) == 0)        // a 60 Hz display: nothing to unlock
        #expect(mulg_display_unity_unlock_target(Int32.min, 120) == 0) // not resolved yet
    }

    @Test("A process without IL2CPP resolves nothing and sets nothing")
    func notUnity() {
        #expect(!mulg_display_unity_frame_rate_resolve())
        #expect(mulg_display_unity_target_frame_rate() == Int32.min)
        #expect(!mulg_display_set_unity_target_frame_rate(120))
    }
}

#if os(macOS) && !targetEnvironment(macCatalyst)
@Suite("Stripped Unity frame-rate resolver")
struct StrippedUnityFrameRateTests {
    @Test func validatesCachedWrappersAndRejectsMalformedOrAmbiguousCode() throws {
        let module = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let hooks = module.appendingPathComponent("Sources/MulgDisplayHooks")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let text = try pipe.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: text, as: UTF8.self))
        }
        let build = try run("/usr/bin/xcrun", ["clang", "-fobjc-arc", "-Wall", "-Werror",
            "-I", hooks.path, "-I", hooks.appendingPathComponent("include").path,
            module.appendingPathComponent("Tests/HookFixtures/StrippedUnityFrameRate.m").path,
            "-framework", "Foundation", "-framework", "QuartzCore", "-o", output.path])
        try #require(build.0 == 0, Comment(rawValue: build.1))
        let result = try run(output.path, [])
        #expect(result.0 == 0, Comment(rawValue: result.1))
    }
}
#endif
