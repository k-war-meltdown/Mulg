#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
@testable import MulgBridgeAppKit
import MulgEngineHooks
import Testing

@MainActor private final class FixtureWindow: NSWindow {
    var mini = false
    var key = false
    override var canBecomeMain: Bool { !mini }
    override var isVisible: Bool { true }
    override var isMiniaturized: Bool { mini }
    override var isKeyWindow: Bool { key }
}

@Suite("AppKit window lifecycle", .serialized) @MainActor
struct WindowLifecycleTests {
    @Test func layerRebindingRefreshesDisplayAndEventsStayInTheBoundWindow() {
        let first = FixtureWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let second = FixtureWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        for window in [first, second] { window.isReleasedWhenClosed = false; window.contentView?.wantsLayer = true }
        defer { first.close(); second.close() }
        let bridge = AppKitBridge()
        first.key = true
        bridge.bindGameLayer(first.contentView!.layer!)
        var updates = 0
        bridge.observeDisplayChanges { _ in updates += 1 }
        bridge.bindGameLayer(first.contentView!.layer!)
        #expect(updates == 0)
        bridge.bindGameLayer(second.contentView!.layer!)
        #expect(updates == 1)
        #expect(AppKitBridge.routesGameplayEvent(window: first, game: first, active: true))
        #expect(!AppKitBridge.routesGameplayEvent(window: second, game: first, active: true))
        #expect(!AppKitBridge.routesGameplayEvent(window: first, game: first, active: false))
        #expect(!AppKitBridge.routesGameplayEvent(window: nil, game: first, active: true))
        #expect(AppKitBridge.routesGameplayEvent(window: nil, game: first, active: true, allowsUnassignedPointer: true))
        #expect(!AppKitBridge.routesGameplayEvent(window: second, game: first, active: true, allowsUnassignedPointer: true))
        first.key = false
        #expect(!AppKitBridge.routesGameplayEvent(window: first, game: first, active: true))
        #expect(!AppKitBridge.routesGameplayEvent(window: nil, game: first, active: true, allowsUnassignedPointer: true))
    }

    @Test func quitHonorsNativeCancellationAndDeferredAcceptance() async {
        // The bridge finds the runtime's swizzle registry by name; this keeps it linked into the tests.
        #expect(mulg_hook_installation_reports() != nil)
        let app = NSApplication.shared, original = app.delegate
        let delegate = FixtureQuitDelegate()
        app.delegate = delegate
        defer { app.delegate = original }
        let bridge = AppKitBridge()
        var quits = 0
        bridge.observeTermination { quits += 1 }
        let selector = #selector(NSApplicationDelegate.applicationShouldTerminate(_:))
        typealias Should = @convention(c) (AnyObject, Selector, NSApplication) -> UInt
        let invoke = unsafeBitCast(class_getMethodImplementation(FixtureQuitDelegate.self, selector), to: Should.self)
        delegate.reply = .terminateCancel
        #expect(invoke(delegate, selector, app) == NSApplication.TerminateReply.terminateCancel.rawValue && quits == 0)
        delegate.reply = .terminateLater
        #expect(invoke(delegate, selector, app) == NSApplication.TerminateReply.terminateLater.rawValue && quits == 0)
        app.reply(toApplicationShouldTerminate: true)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(quits == 1)
        delegate.reply = .terminateNow
        #expect(invoke(delegate, selector, app) == NSApplication.TerminateReply.terminateLater.rawValue)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(quits == 1)
    }
    @Test func onlyTheLastGameWindowClosesTheSession() {
        let app = NSApplication.shared
        let first = FixtureWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let second = FixtureWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        for window in [first, second, panel] { window.isReleasedWhenClosed = false }
        defer { first.close(); second.close(); panel.close() }
        #expect(app.windows.contains(first) && app.windows.contains(second))
        let bridge = AppKitBridge()
        var closes = 0
        var onScreen = false
        bridge.observeWindowClosing { closes += 1 }
        bridge.observeWindowFocus { _, shown in onScreen = shown }
        first.key = true
        second.mini = true
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: panel)
        #expect(onScreen)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: first)
        #expect(closes == 0)
        second.mini = false
        second.key = true
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: second)
        #expect(onScreen)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: panel)
        #expect(closes == 0)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: second)
        #expect(closes == 1)
    }
}

@MainActor private final class FixtureQuitDelegate: NSObject, NSApplicationDelegate {
    var reply = NSApplication.TerminateReply.terminateCancel
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { reply }
}
#endif
