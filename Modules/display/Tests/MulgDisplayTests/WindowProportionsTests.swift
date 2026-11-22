#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import Testing
import MulgContracts
import MulgEngine
import MulgBridgeAppKit
@testable import MulgDisplay

@Suite("Live window proportions", .serialized) @MainActor
struct WindowProportionsTests {
    @Test("Resolution changes apply their proportions to the existing window")
    func selectedResolutionChangesLive() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.wantsLayer = true
        let bridge = AppKitBridge(), module = DisplayModule()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { bridge.rememberWindowFrame(false); window.close(); try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root)
        var settings = GameSettings()
        settings.resolution = ResolutionMode.auto.rawValue
        settings.mulg.display.retina = true
        settings.mulg.display.uncapFrameRate = false
        let context = ModuleContext(bundleIdentifier: "window.proportions", paths: paths,
            settingsStore: SettingsStore(paths: paths), settings: settings, launch: .normal, bridge: bridge)
        bridge.bindGameLayer(try #require(window.contentView?.layer))
        module.applyWindowPreferences(context)
        func change(_ edit: (inout GameSettings) -> Void) {
            let old = context.settings
            let updated = context.updateSettings(edit)
            #expect(updated)
            module.settingsChanged(from: old, context: context)
        }
        func expectRatio(_ value: Double) throws {
            let aspect = window.contentAspectRatio
            #expect(abs(aspect.width / aspect.height - value) < 0.000001)
            let content = try #require(window.contentView)
            #expect(abs(content.bounds.width / content.bounds.height - value) < 0.01)
            #expect(window.styleMask.contains(.resizable))
        }
        change { $0.resolution = ResolutionMode.native4K.rawValue }
        try expectRatio(16.0 / 9)
        #expect(context.settings.fixedRenderSize?.width == 3840)
        #expect(context.settings.fixedRenderSize?.height == 2160)
        change { $0.resolution = ResolutionMode.native5K.rawValue }
        try expectRatio(16.0 / 9)
        #expect(context.settings.fixedRenderSize?.width == 5120)
        change { $0.mulg.display.retina = false }
        try expectRatio(16.0 / 9)
        change {
            $0.resolution = ResolutionMode.auto.rawValue
            $0.resizableAspectRatioWidth = 4
            $0.resizableAspectRatioHeight = 3
        }
        try expectRatio(4.0 / 3)
        // Changing only custom proportions must not be lost behind the display
        // policy's resolution/power guard. Free resizing remains available.
        change { $0.resizableAspectRatioWidth = 0; $0.resizableAspectRatioHeight = 0 }
        #expect(window.contentAspectRatio == .zero)
    }
}
#endif
