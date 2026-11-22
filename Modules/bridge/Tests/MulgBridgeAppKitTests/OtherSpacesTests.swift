#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import ObjectiveC
import Testing
@testable import MulgBridgeAppKit

/// A stand-in for UIKitMacHelper's `UINSWindowStateController` (absent outside Mac Catalyst apps)
/// with the same update selector, so the hook is tested on the real swizzle path.
private enum FakeStateController {
    nonisolated(unsafe) static var updates = 0

    static func make() -> AnyClass {
        if let existing = NSClassFromString("UINSWindowStateController") { return existing }
        let cls: AnyClass = objc_allocateClassPair(NSObject.self, "UINSWindowStateController", 0)!
        let update: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, Bool) -> Void = { _, _, _, _, _ in
            updates += 1
        }
        class_addMethod(cls, NSSelectorFromString("_updateWindowState:forWindow:sceneIdentifier:performingStateChangeIfNecessary:"),
                        imp_implementationWithBlock(update), "v@:@@@B")
        // macOS 27 splits the update into a scene and a window variant.
        let update2: @convention(block) (AnyObject, AnyObject?, Bool) -> Void = { _, _, _ in updates += 1 }
        for name in ["_updateWindowStateForScene:performingStateChangeIfNecessary:",
                     "_updateWindowStateForWindow:performingStateChangeIfNecessary:"] {
            class_addMethod(cls, NSSelectorFromString(name), imp_implementationWithBlock(update2), "v@:@B")
        }
        objc_registerClassPair(cls)
        return cls
    }
}

@Suite("Other Spaces", .serialized) @MainActor
struct OtherSpacesTests {
    @Test("Only a visible, not minimised window on another Space skips UIKit's background decision")
    func skipRule() {
        #expect(AppKitBridge.skipsSpaceUpdate(enabled: true, minimized: false, visible: true, onActiveSpace: false))
        #expect(!AppKitBridge.skipsSpaceUpdate(enabled: true, minimized: false, visible: true, onActiveSpace: true))
        #expect(!AppKitBridge.skipsSpaceUpdate(enabled: true, minimized: true, visible: true, onActiveSpace: false))
        #expect(!AppKitBridge.skipsSpaceUpdate(enabled: true, minimized: false, visible: false, onActiveSpace: false))
        #expect(!AppKitBridge.skipsSpaceUpdate(enabled: false, minimized: false, visible: true, onActiveSpace: false))
    }

    @Test("Every other update still reaches UIKit through the hook")
    func passesThrough() throws {
        let cls = FakeStateController.make() as! NSObject.Type
        let controller = cls.init()
        AppKitBridge().keepForegroundOnOtherSpaces(true)
        let selector = NSSelectorFromString("_updateWindowState:forWindow:sceneIdentifier:performingStateChangeIfNecessary:")
        typealias Update = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, Bool) -> Void
        let imp = try #require(class_getMethodImplementation(cls, selector))
        let before = FakeStateController.updates
        // No window (a system scene) and an off-screen window: both are UIKit's to decide.
        unsafeBitCast(imp, to: Update.self)(controller, selector, nil, nil, nil, true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
        unsafeBitCast(imp, to: Update.self)(controller, selector, nil, window, nil, true)
        #expect(FakeStateController.updates == before + 2)
    }

    @Test("The macOS 27 scene and window updates are hooked and pass through when nothing is on another Space")
    func splitUpdatesPassThrough() throws {
        let cls = FakeStateController.make() as! NSObject.Type
        let controller = cls.init()
        AppKitBridge().keepForegroundOnOtherSpaces(true)
        typealias Update = @convention(c) (AnyObject, Selector, AnyObject?, Bool) -> Void
        let before = FakeStateController.updates
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
        for (name, argument) in [("_updateWindowStateForScene:performingStateChangeIfNecessary:", nil as AnyObject?),
                                 ("_updateWindowStateForWindow:performingStateChangeIfNecessary:", window)] {
            let selector = NSSelectorFromString(name)
            let imp = try #require(class_getMethodImplementation(cls, selector))
            unsafeBitCast(imp, to: Update.self)(controller, selector, argument, true)
        }
        // No game window here, and an ordered-out window: both are UIKit's to decide.
        #expect(FakeStateController.updates == before + 2)
    }
}
#endif
