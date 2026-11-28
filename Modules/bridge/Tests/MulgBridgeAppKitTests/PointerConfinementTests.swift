#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Testing
@testable import MulgBridgeAppKit

@Suite("Pointer confinement")
struct PointerConfinementTests {
    @Test("A resizable window keeps its resize border; full screen and fixed windows use the whole content")
    func region() {
        let content = CGRect(x: 100, y: 200, width: 800, height: 600)
        #expect(PointerConfinement.region(content: content, resizable: true, fullscreen: false)
                == CGRect(x: 111, y: 211, width: 778, height: 578))
        #expect(PointerConfinement.region(content: content, resizable: true, fullscreen: true)
                == CGRect(x: 101, y: 201, width: 798, height: 598))
        #expect(PointerConfinement.region(content: content, resizable: false, fullscreen: false)
                == CGRect(x: 101, y: 201, width: 798, height: 598))
        // A window too small to hold the pointer, or one being set up, confines nothing.
        #expect(PointerConfinement.region(content: CGRect(x: 0, y: 0, width: 20, height: 20),
                                          resizable: true, fullscreen: false) == nil)
        #expect(PointerConfinement.region(content: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
                                          resizable: false, fullscreen: false) == nil)
    }

    @Test("A pointer outside goes to the nearest point inside; one inside stays where it is")
    func clamp() {
        let region = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(PointerConfinement.clamp(CGPoint(x: 40, y: 20), to: region) == CGPoint(x: 40, y: 20))
        #expect(PointerConfinement.clamp(CGPoint(x: -30, y: 20), to: region) == CGPoint(x: 0, y: 20))
        #expect(PointerConfinement.clamp(CGPoint(x: 400, y: 90), to: region) == CGPoint(x: 99, y: 49))
        #expect(PointerConfinement.clamp(CGPoint(x: 100, y: 50), to: region) == CGPoint(x: 99, y: 49))
        #expect(PointerConfinement.contains(CGPoint(x: 99, y: 0), region))
        #expect(!PointerConfinement.contains(CGPoint(x: 100, y: 0), region))
    }

    @Test("AppKit and Core Graphics coordinates convert both ways")
    func flip() {
        let rect = CGRect(x: 10, y: 100, width: 200, height: 300)
        let flipped = PointerConfinement.flipped(rect, firstScreenMaxY: 1000)
        #expect(flipped == CGRect(x: 10, y: 600, width: 200, height: 300))
        #expect(PointerConfinement.flipped(flipped, firstScreenMaxY: 1000) == rect)
        #expect(PointerConfinement.flipped(CGPoint(x: 5, y: 900), firstScreenMaxY: 1000) == CGPoint(x: 5, y: 100))
    }

    @Test("Only a game in play holds the pointer; macOS's own ways out free it")
    func applies() {
        func applies(requested: Bool = true, released: Bool = true, active: Bool = true, hidden: Bool = false, gameKey: Bool = true,
                     minimized: Bool = false, onActiveSpace: Bool = true, windowInteraction: Bool = false,
                     resizing: Bool = false, transitioning: Bool = false, captured: Bool = false) -> Bool {
            PointerConfinement.applies(requested: requested, released: released, active: active, hidden: hidden, gameKey: gameKey,
                minimized: minimized, onActiveSpace: onActiveSpace, windowInteraction: windowInteraction,
                resizing: resizing, transitioning: transitioning, captured: captured)
        }
        #expect(applies())
        #expect(!applies(requested: false))
        #expect(!applies(released: false))        // Camera mode: Alt or a middle click not used.
        #expect(!applies(active: false))          // ⌘Tab to another app.
        #expect(!applies(hidden: true))
        #expect(!applies(gameKey: false))         // Another window of the game is in front.
        #expect(!applies(minimized: true))
        #expect(!applies(onActiveSpace: false))   // Swiped to another Space.
        #expect(!applies(windowInteraction: true)) // Title bar or traffic-light drag.
        #expect(!applies(resizing: true))
        #expect(!applies(transitioning: true))    // Entering or leaving full screen.
        #expect(!applies(captured: true))         // The locked camera cursor is held already.
    }
    @Test("The keybind lock adds only valid presentation options and removes only its own")
    func keybindLockOptions() {
        let lock: NSApplication.PresentationOptions = [.disableProcessSwitching, .disableHideApplication]
        #expect(PointerConfinement.keybindLockOptions(current: []) == lock.union(.autoHideDock))
        let fullScreen: NSApplication.PresentationOptions = [.fullScreen, .autoHideDock, .autoHideMenuBar]
        #expect(PointerConfinement.keybindLockOptions(current: fullScreen) == lock)
        #expect(PointerConfinement.keybindLockOptions(current: [.fullScreen]).isEmpty)
        #expect(PointerConfinement.keybindLockOptions(current: lock.union(.hideDock)).isEmpty)
        let added = lock.union(.autoHideDock)
        #expect(PointerConfinement.keybindUnlockOptions(current: added, added: added).isEmpty)
        // A menu bar auto-hidden meanwhile keeps the Dock option it needs.
        #expect(PointerConfinement.keybindUnlockOptions(current: added.union(.autoHideMenuBar), added: added)
            == [.autoHideMenuBar, .autoHideDock])
        #expect(PointerConfinement.keybindUnlockOptions(current: fullScreen.union(lock), added: lock) == fullScreen)
    }
}
#endif
