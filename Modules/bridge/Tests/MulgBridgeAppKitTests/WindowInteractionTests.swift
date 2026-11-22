#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Testing
@testable import MulgBridgeAppKit

@Suite("Native window interaction", .serialized) @MainActor
struct WindowInteractionTests {
    @Test("Title bars and resize corners never enter the gameplay mouse mapper")
    func chromeAndContent() {
        let content = CGRect(x: 0, y: 0, width: 800, height: 600)
        let frame = CGSize(width: 800, height: 628)
        func routes(_ point: CGPoint, fullscreen: Bool = false) -> Bool {
            AppKitBridge.routesGameplayPointer(point: point, contentRect: content,
                frameSize: frame, resizable: true, fullscreen: fullscreen)
        }
        #expect(!routes(CGPoint(x: 400, y: 614))) // Native title-bar movement.
        for point in [CGPoint(x: 5, y: 5), CGPoint(x: 795, y: 5),
                      CGPoint(x: 5, y: 590), CGPoint(x: 795, y: 590)] {
            #expect(!routes(point))
        }
        #expect(routes(CGPoint(x: 400, y: 300)))
        #expect(routes(CGPoint(x: 5, y: 5), fullscreen: true)) // No resize border in fullscreen.
        #expect(!routes(CGPoint(x: -1, y: 300)))
    }

    @Test("Releasing the cursor modifier cannot reclaim an active native window drag")
    func gestureLifetime() {
        _ = NSApplication.shared
        let bridge = AppKitBridge()
        bridge.beginWindowInteraction(button: 0)
        #expect(bridge.isWindowInteractionActive)
        bridge.hideCursor() // Option released: gameplay requests capture during the drag.
        bridge.warpCursor() // Must leave the system's window drag alone.
        #expect(bridge.isWindowInteractionActive)
        bridge.beginWindowInteraction(button: 1)
        bridge.endWindowInteraction(button: 0)
        #expect(bridge.isWindowInteractionActive)
        bridge.endWindowInteraction(button: 1)
        #expect(!bridge.isWindowInteractionActive)
        bridge.unhideCursor()
    }

    @Test("Actual AppKit content-layout geometry keeps traffic lights and the title bar native")
    func nativeWindowGeometry() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let bridge = AppKitBridge()
        func event(_ point: CGPoint) throws -> NSEvent {
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            #expect(event.window === window)
            return event
        }
        #expect(bridge.isWindowManagementEvent(try event(CGPoint(x: 400, y: window.frame.height - 5))))
        #expect(bridge.isWindowManagementEvent(try event(CGPoint(x: 5, y: 5))))
        #expect(!bridge.isWindowManagementEvent(try event(CGPoint(x: 400, y: 300))))
        let close = try #require(window.standardWindowButton(.closeButton))
        #expect(bridge.isWindowManagementEvent(try event(close.convert(
            CGPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil))))
    }
}
#endif