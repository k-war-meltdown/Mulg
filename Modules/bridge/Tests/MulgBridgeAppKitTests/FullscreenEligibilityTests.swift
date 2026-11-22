#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import Testing
@testable import MulgBridgeAppKit

@Suite("Native fullscreen eligibility", .serialized) @MainActor
struct FullscreenEligibilityTests {
    /// AppKit's canEnterFullScreenMode refuses a window without FullScreenPrimary, with FullScreenNone
    /// or with private bit 15, and toggleFullScreen: then silently does nothing.
    @Test func gameWindowsStayEligibleAndRestoreOnRelease() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let veto = NSWindow.CollectionBehavior(rawValue: 1 << 15)
        let original: NSWindow.CollectionBehavior = [.fullScreenNone, .canJoinAllSpaces, veto]
        window.collectionBehavior = original

        let controller = NativeGameFullscreen(window: window) { _ in }
        let behavior = window.collectionBehavior
        #expect(behavior.contains(.fullScreenPrimary) && behavior.contains(.managed))
        #expect(!behavior.contains(.fullScreenNone) && !behavior.contains(.canJoinAllSpaces) && !behavior.contains(veto))
        #expect(window.styleMask.contains(.resizable))
        #expect(!controller.ownsPresentation)

        controller.restore()
        #expect(window.collectionBehavior == original)
    }

    /// macOS 27's green button calls the window's private _setNeedsZoom: and nothing else, so a
    /// managed window must take that request as its fullscreen toggle.
    @Test func greenButtonRequestStartsTheFullscreenTransition() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let controller = NativeGameFullscreen(window: window) { _ in }
        defer { controller.restore() }
        #expect(!controller.ownsPresentation)

        window.perform(NSSelectorFromString("_setNeedsZoom:"), with: nil)
        #expect(controller.ownsPresentation, "the green button's request is the fullscreen toggle")
    }
}
#endif
