import CoreGraphics
import Foundation
import Metal
import MulgContracts
@testable import MulgGraphics
import MulgGraphicsHooks
import Testing

@Suite("Forced resolution", .serialized)
struct ForcedResolutionTests {
    @Test("On by default, with explicit per-game off preserved")
    func desktopDefaultAndSavedOverride() throws {
        #expect(GraphicsSettings().forceRenderResolution)
        var settings = GraphicsSettings()
        settings.forceRenderResolution = false
        let decoded = try JSONDecoder().decode(GraphicsSettings.self, from: JSONEncoder().encode(settings))
        #expect(!decoded.forceRenderResolution)
        #expect(try JSONDecoder().decode(GraphicsSettings.self, from: Data("{}".utf8)).forceRenderResolution == true)
    }

    @Test("Any known request becomes exactly the chosen target, smaller or larger")
    func exactTarget() {
        let target = MulgForcedSize(width: 4609, height: 2880)
        let raised = mulg_graphics_forced_size(MulgForcedSize(width: 1728, height: 1080), target)
        #expect(raised.width == 4609 && raised.height == 2880)
        let larger = mulg_graphics_forced_size(MulgForcedSize(width: 5120, height: 3200), target)
        #expect(larger.width == 4609 && larger.height == 2880)
        let unknown = mulg_graphics_forced_size(MulgForcedSize(width: 1728, height: 1080), MulgForcedSize(width: 0, height: 0))
        #expect(unknown.width == 1728 && unknown.height == 1080)
    }

    @Test("The target is the window's shape at the selected height, or at the screen's density")
    func target() throws {
        let selected = try #require(GraphicsModule.forcedTarget(points: CGSize(width: 1871, height: 1169), renderHeight: 2880, scale: 2))
        #expect(selected.height == 2880 && selected.width == 4609)
        let native = try #require(GraphicsModule.forcedTarget(points: CGSize(width: 1600, height: 900), renderHeight: nil, scale: 2))
        #expect(native.width == 3200 && native.height == 1800)
        #expect(GraphicsModule.forcedTarget(points: .zero, renderHeight: 1080, scale: 2) == nil)
        #expect(GraphicsModule.forcedTarget(points: CGSize(width: 100, height: 10), renderHeight: 8000, scale: 2) == nil)
    }

    @Test("Fixed 4K and 5K game settings retain both dimensions on a differently shaped view")
    func fixedPresetTargets() throws {
        var settings = GameSettings()
        settings.mulg.display.retina = true
        // Reproduce the wide runtime view which previously turned 4K into 4151x2160.
        let points = CGSize(width: 4151, height: 2160)
        for (mode, width, height) in [(ResolutionMode.native4K, 3840, 2160), (.native5K, 5120, 2880)] {
            settings.resolution = mode.rawValue
            let target = try #require(GraphicsModule.forcedTarget(points: points,
                renderHeight: settings.targetRenderHeight, scale: 2, fixedSize: settings.fixedRenderSize))
            #expect(target.width == width && target.height == height)
        }
        #expect(GraphicsModule.forcedTarget(points: points, renderHeight: 2160, scale: 2,
            fixedSize: (0, 2160)) == nil)
    }

    @Test("Retina off follows the current view size independently of the selected resolution")
    func retinaRenderSurface() throws {
        var settings = GameSettings()
        settings.resolution = ResolutionMode.native4K.rawValue
        #expect(GraphicsModule.renderSurfaceHeight(settings) == 2160)
        settings.mulg.display.retina = false
        #expect(GraphicsModule.renderSurfaceHeight(settings) == -1)
        settings.resolution = ResolutionMode.auto.rawValue
        #expect(GraphicsModule.renderSurfaceHeight(settings) == -1)
        let before = try #require(GraphicsModule.forcedTarget(points: CGSize(width: 1600, height: 900), renderHeight: nil, scale: 1))
        let after = try #require(GraphicsModule.forcedTarget(points: CGSize(width: 1200, height: 800), renderHeight: nil, scale: 1))
        #expect(before.width == 1600 && before.height == 900)
        #expect(after.width == 1200 && after.height == 800)
    }

    @Test("Without Unity's exports the drawable-size path is used")
    func noUnityHere() {
        mulg_graphics_reset_forced_resolution_for_testing()
        defer { mulg_graphics_reset_forced_resolution_for_testing() }
        #expect(mulg_graphics_unity_resolution_install() == .unavailable)
        mulg_graphics_set_forced_resolution(true, 4609, 2880)
        #expect(mulg_graphics_forced_resolution_enabled())
        #expect(!mulg_graphics_unity_apply_resolution())
        let report = mulg_graphics_forced_resolution_report() as? [String: Any]
        #expect(report?["forcedResolutionPath"] as? String == "engine render view")
        #expect(report?["forcedTargetHeight"] as? Int == 2880)
    }

    @Test("Any Unity player: its rendering-size request is raised, re-sent and given back")
    func unityPlayerRequest() throws {
        mulg_graphics_reset_forced_resolution_for_testing()
        defer { mulg_graphics_reset_forced_resolution_for_testing() }
        let connection = try #require(FakeDisplayConnection.make())
        #expect(mulg_graphics_install_unity_display_hook())
        #expect(mulg_graphics_install_unity_display_hook())
        let display = connection.init()

        mulg_graphics_set_forced_resolution(true, 2880, 1800)
        FakeDisplayConnection.send(display, CGSize(width: 1920, height: 1200))
        #expect(FakeDisplayConnection.received == CGSize(width: 2880, height: 1800))
        #expect(!mulg_graphics_unity_display_apply())

        // Window grows: the same request is raised again to the new target.
        mulg_graphics_set_forced_resolution(true, 3200, 2000)
        #expect(mulg_graphics_unity_display_apply())
        #expect(FakeDisplayConnection.received == CGSize(width: 3200, height: 2000))

        // Off: the game gets its own size back. On: a larger request comes down to the choice; native stays native.
        mulg_graphics_set_forced_resolution(false, 3200, 2000)
        #expect(mulg_graphics_unity_display_apply())
        #expect(FakeDisplayConnection.received == CGSize(width: 1920, height: 1200))
        mulg_graphics_set_forced_resolution(true, 2880, 1800)
        FakeDisplayConnection.send(display, CGSize(width: 3840, height: 2400))
        #expect(FakeDisplayConnection.received == CGSize(width: 2880, height: 1800))
        FakeDisplayConnection.send(display, .zero)
        #expect(FakeDisplayConnection.received == .zero)

        let report = mulg_graphics_forced_resolution_report() as? [String: Any]
        #expect(report?["forcedResolutionPath"] as? String == "Unity player rendering size")
        #expect(report?["unityPlayerOverrides"] as? Int == 3)
    }

    @Test("Unity render scale: without IL2CPP's exports nothing is called")
    func renderScaleWithoutIL2CPP() {
        #expect(mulg_graphics_unity_render_scale_apply(true) == .unavailable)
        #expect(mulg_graphics_unity_render_scale_apply(false) == .none)
        let report = mulg_graphics_unity_render_scale_report() as? [String: Any]
        #expect(report?["unityRenderScaleApplied"] as? Int == 0)
    }

    @Test("Unity highest quality: off by default, kept when saved, and nothing is called outside Unity")
    func unityQualityOutsideUnity() throws {
        #expect(!GraphicsSettings().unityHighestQuality)
        var settings = GraphicsSettings()
        settings.unityHighestQuality = true
        let decoded = try JSONDecoder().decode(GraphicsSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.unityHighestQuality)
        mulg_graphics_unity_quality_apply(true)
        mulg_graphics_unity_quality_apply(false)
        let report = mulg_graphics_unity_render_scale_report() as? [String: Any]
        #expect(report?["unityQualitySets"] as? Int == 0 && report?["unityQualityLevel"] as? Int == -1)
    }

    @Test("Render-pass report lists recorded sizes, most used first (1012 crashed here)")
    func renderPassReport() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func texture(_ width: Int, _ height: Int) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = .renderTarget
            return try #require(device.makeTexture(descriptor: descriptor))
        }
        let wide = try texture(97, 61), small = try texture(13, 11)
        for _ in 0..<3 { mulg_graphics_record_pass_for_testing(wide) }
        mulg_graphics_record_pass_for_testing(small)
        mulg_graphics_record_pass_for_testing(nil)
        let lines = mulg_graphics_render_pass_sizes()
        let wideLine = try #require(lines.firstIndex(of: "97x61: 3 passes"))
        let smallLine = try #require(lines.firstIndex(of: "13x11: 1 passes"))
        #expect(wideLine < smallLine)
        _ = mulg_graphics_recent_render_pass_sizes()
        mulg_graphics_record_pass_for_testing(wide)
        let recent = mulg_graphics_recent_render_pass_sizes()
        let sizes = try #require(recent["sizes"] as? [[String: Int]])
        #expect(sizes.contains { $0["width"] == 97 && $0["height"] == 61 && $0["passes"] == 1 })
        #expect(!(try #require(mulg_graphics_recent_render_pass_sizes()["sizes"] as? [[String: Int]])).contains { $0["width"] == 97 })
    }

    @Test("Hooked after the game asked: Unity's main display request is adopted and raised")
    func unityPlayerLateHook() throws {
        mulg_graphics_reset_forced_resolution_for_testing()
        defer { mulg_graphics_reset_forced_resolution_for_testing() }
        _ = try #require(FakeDisplayConnection.make())
        let display = try #require(FakeDisplayConnection.makeManager())
        #expect(mulg_graphics_install_unity_display_hook())
        FakeDisplayConnection.stored = CGSize(width: 1920, height: 1200)
        FakeDisplayConnection.received = CGSize(width: -1, height: -1)

        mulg_graphics_set_forced_resolution(true, 2880, 1800)
        #expect(mulg_graphics_unity_display_apply())
        #expect(FakeDisplayConnection.received == CGSize(width: 2880, height: 1800))
        #expect(!mulg_graphics_unity_display_apply())
        let report = mulg_graphics_forced_resolution_report() as? [String: Any]
        #expect(report?["unityPlayerRequest"] as? String == "1920x1200")

        // A known natural surface (0x0) can be explicitly resized and restored through Unity.
        mulg_graphics_reset_forced_resolution_for_testing()
        FakeDisplayConnection.stored = .zero
        FakeDisplayConnection.received = CGSize(width: -1, height: -1)
        mulg_graphics_set_forced_resolution(true, 2880, 1800)
        #expect(mulg_graphics_unity_display_apply())
        #expect(FakeDisplayConnection.received == CGSize(width: 2880, height: 1800))
        mulg_graphics_set_forced_resolution(false, 2880, 1800)
        #expect(mulg_graphics_unity_display_apply())
        #expect(FakeDisplayConnection.received == .zero)
        withExtendedLifetime(display) {}
    }
}

/// Stands in for the Unity trampoline class, with the same selector and argument type.
private enum FakeDisplayConnection {
    nonisolated(unsafe) static var received = CGSize(width: -1, height: -1)
    nonisolated(unsafe) static var stored = CGSize.zero
    private nonisolated(unsafe) static var main: NSObject?
    private nonisolated(unsafe) static var registered: NSObject.Type?

    static func make() -> NSObject.Type? {
        if let registered { return registered }
        guard let cls = objc_allocateClassPair(NSObject.self, "DisplayConnection", 0) else {
            return NSClassFromString("DisplayConnection") as? NSObject.Type
        }
        let block: @convention(block) (NSObject, CGSize) -> Void = { _, size in received = size }
        let types = "v@:{CGSize=dd}"
        class_addMethod(cls, NSSelectorFromString("requestRenderingResolution:"), imp_implementationWithBlock(block), types)
        let getter: @convention(block) (NSObject) -> CGSize = { _ in stored }
        class_addMethod(cls, NSSelectorFromString("requestedRenderingSize"), imp_implementationWithBlock(getter), "{CGSize=dd}@:")
        objc_registerClassPair(cls)
        registered = cls as? NSObject.Type
        return registered
    }

    /// Unity's DisplayManager: +Instance and its mainDisplay.
    static func makeManager() -> NSObject? {
        if let main { return main }
        guard let connection = make(), let manager = objc_allocateClassPair(NSObject.self, "DisplayManager", 0),
              let meta = object_getClass(manager) else { return nil }
        let display = connection.init()
        let shared = NSObject()
        let instance: @convention(block) (AnyObject) -> AnyObject = { _ in shared }
        let mainDisplay: @convention(block) (AnyObject) -> AnyObject = { _ in display }
        class_addMethod(meta, NSSelectorFromString("Instance"), imp_implementationWithBlock(instance), "@@:")
        objc_registerClassPair(manager)
        object_setClass(shared, manager)
        class_addMethod(manager, NSSelectorFromString("mainDisplay"), imp_implementationWithBlock(mainDisplay), "@@:")
        main = display
        return display
    }

        static func send(_ display: NSObject, _ size: CGSize) {
        typealias Request = @convention(c) (NSObject, Selector, CGSize) -> Void
        let selector = NSSelectorFromString("requestRenderingResolution:")
        unsafeBitCast(display.method(for: selector), to: Request.self)(display, selector, size)
    }
}
