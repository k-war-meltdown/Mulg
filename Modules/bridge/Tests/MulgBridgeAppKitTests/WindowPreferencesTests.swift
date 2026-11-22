#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import Testing
@testable import MulgBridgeAppKit

@Suite("Reversible window preferences", .serialized) @MainActor
struct WindowPreferencesTests {
    @Test("Windowed resize restores the selected ratio after a native scene constraint reset")
    func proportionalResizeAfterConstraintReset() throws {
        _ = NSApplication.shared
        func makeWindow() -> NSWindow {
            let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            result.isReleasedWhenClosed = false
            result.contentView?.wantsLayer = true
            return result
        }
        let window = makeWindow(), other = makeWindow(), bridge = AppKitBridge()
        defer { window.close(); other.close() }
        window.contentAspectRatio = NSSize(width: 4, height: 3)
        bridge.bindGameLayer(try #require(window.contentView?.layer))
        bridge.applyWindowPreferences(hideTitleBar: false, floating: false, aspectWidth: 3840, aspectHeight: 2160)
        var resizing: [Bool] = []
        bridge.observeLiveResize { resizing.append($0) }
        window.contentAspectRatio = .zero // UIKit replaced its size restrictions.
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: other)
        #expect(window.contentAspectRatio == .zero)
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: other)
        resizing.removeAll()
        let size = window.contentView?.bounds.size
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        #expect(abs(window.contentAspectRatio.width / window.contentAspectRatio.height - 16.0 / 9) < 0.000001)
        #expect(window.contentView?.bounds.size == size) // No renderer resize at drag start.
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        #expect(resizing == [true, false])
        bridge.applyWindowPreferences(hideTitleBar: false, floating: false, aspectWidth: 0, aspectHeight: 0)
        #expect(window.contentAspectRatio == NSSize(width: 4, height: 3))
    }

    @Test("Game content receives mouse events and restores native policy when rebound")
    func contentInputOwnership() throws {
        _ = NSApplication.shared
        func window() -> NSWindow {
            let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            result.isReleasedWhenClosed = false
            result.contentView?.wantsLayer = true
            return result
        }
        let first = window(), second = window(), bridge = AppKitBridge()
        defer { first.close(); second.close() }
        first.isMovableByWindowBackground = true
        first.acceptsMouseMovedEvents = false
        second.isMovableByWindowBackground = false
        second.acceptsMouseMovedEvents = true
        let firstLayer = try #require(first.contentView?.layer)
        let secondLayer = try #require(second.contentView?.layer)
        bridge.bindGameLayer(firstLayer)
        #expect(!first.isMovableByWindowBackground && first.acceptsMouseMovedEvents)
        #expect(first.isMovable) // Title-bar dragging remains available.
        bridge.applyWindowPreferences(hideTitleBar: true, floating: false, aspectWidth: 0, aspectHeight: 0)
        bridge.applyWindowPreferences(hideTitleBar: false, floating: false, aspectWidth: 0, aspectHeight: 0)
        #expect(!first.isMovableByWindowBackground && first.acceptsMouseMovedEvents)
        bridge.bindGameLayer(secondLayer)
        #expect(first.isMovableByWindowBackground && !first.acceptsMouseMovedEvents)
        #expect(!second.isMovableByWindowBackground && second.acceptsMouseMovedEvents)
        bridge.bindGameLayer(firstLayer)
        #expect(!second.isMovableByWindowBackground && second.acceptsMouseMovedEvents)
        #expect(!first.isMovableByWindowBackground && first.acceptsMouseMovedEvents)
    }

    @Test func clearingAndRebindingRestoreNativeValues() throws {
        _ = NSApplication.shared
        func window(_ title: String) -> NSWindow {
            let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            result.isReleasedWhenClosed = false
            result.contentView?.wantsLayer = true
            result.title = title
            return result
        }
        let first = window("First"), second = window("Second"), bridge = AppKitBridge()
        defer { first.close(); second.close() }
        first.level = .statusBar
        first.toolbar = NSToolbar(identifier: "original")
        let toolbar = first.toolbar
        first.contentAspectRatio = NSSize(width: 4, height: 3)
        bridge.bindGameLayer(try #require(first.contentView?.layer))
        bridge.applyWindowPreferences(hideTitleBar: true, floating: true, aspectWidth: 16, aspectHeight: 9)
        let content = try #require(first.contentView)
        #expect(abs(content.bounds.width / content.bounds.height - 16.0 / 9) < 0.01)
        #expect(first.isMovable && first.styleMask.contains(.resizable))
        #expect(first.titleVisibility == .hidden && first.toolbar == nil && first.level == .floating)
        bridge.applyWindowPreferences(hideTitleBar: false, floating: false, aspectWidth: 0, aspectHeight: 0)
        #expect(first.title == "First" && first.titleVisibility == .visible && first.toolbar === toolbar)
        #expect(first.level == .statusBar && first.contentAspectRatio == NSSize(width: 4, height: 3))
        #expect(!first.styleMask.contains(.fullSizeContentView) && !first.titlebarAppearsTransparent)
        // Capture the latest native values when a new override starts.
        first.title = "Changed"
        bridge.applyWindowPreferences(hideTitleBar: true, floating: true, aspectWidth: 16, aspectHeight: 9)
        bridge.bindGameLayer(try #require(second.contentView?.layer))
        #expect(first.title == "Changed" && first.toolbar === toolbar && first.level == .statusBar)
        #expect(second.titleVisibility == .hidden && second.level == .floating)
        #expect(second.contentAspectRatio == NSSize(width: 16, height: 9))
        bridge.applyWindowPreferences(hideTitleBar: false, floating: false, aspectWidth: 0, aspectHeight: 0)
        #expect(second.title == "Second" && second.level == .normal && second.contentAspectRatio == .zero)
    }
}
#endif
