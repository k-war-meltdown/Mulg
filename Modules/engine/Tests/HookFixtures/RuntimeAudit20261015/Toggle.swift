import Foundation
import CoreGraphics
enum TouchPhase { case began, moved, ended }
@MainActor final class Injector {
    var attempts = 0
    func touch(_ id: inout Int?, at point: CGPoint, phase: TouchPhase) {
        if phase == .began { attempts += 1; if attempts > 1 { id = attempts } }
        else if phase == .ended { id = nil }
    }
    func waitForBegin(_ id: Int, timeout: Duration) async -> Bool { true }
}
@MainActor final class Button {
    let injector = Injector()
    var hudAvailable = true, toggles = true, held = false, liveResizing = false, resizeSettling = false
    var tapDuration: Double?, tapKeyDown = false, touchID: Int?, tapTask: Task<Void, Never>?
    var point = CGPoint.zero
    func invalidate() { touchID = nil; held = false }
    // __PRODUCTION__
}
Task { @MainActor in
    let button = Button()
    button.update(pressed: true); button.update(pressed: false)
    assert(button.touchID == nil)
    button.update(pressed: true); button.update(pressed: false)
    assert(button.touchID != nil && button.injector.attempts == 2, "The next toggle press must retry a rejected begin")
    button.update(pressed: true)
    assert(button.touchID == nil)
    print("PASS: rejected toggle begins retry on the next press and normal latching still works")
    exit(0)
}
dispatchMain()
