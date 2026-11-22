import Foundation
import CoreGraphics
public enum TouchPhase { case began, moved, ended }
public struct ScreenMetrics { var width: CGFloat = 1000; var height: CGFloat = 500 }
@MainActor public protocol TouchInjecting: AnyObject {
    func touch(_ id: inout Int?, at point: CGPoint, phase: TouchPhase)
    func cancel(_ id: inout Int?, at point: CGPoint)
}
@MainActor final class Injector: TouchInjecting {
    var next = 0, failOnMove = 0, moves = 0
    var live: Set<Int> = []
    func touch(_ id: inout Int?, at point: CGPoint, phase: TouchPhase) {
        switch phase {
        case .began: id = next; live.insert(next); next += 1
        case .moved:
            guard let current = id else { return }
            moves += 1
            if moves == failOnMove { live.remove(current); id = nil }
        case .ended: cancel(&id, at: point)
        }
    }
    func cancel(_ id: inout Int?, at point: CGPoint) {
        if let id { live.remove(id) }; id = nil
    }
}
// __PRODUCTION__
Task { @MainActor in
    for failedFinger in [1, 2] {
        let injector = Injector(); injector.failOnMove = failedFinger
        let zoom = PinchZoom(injector: injector) { ScreenMetrics() }
        zoom.scroll(10)
        assert(!zoom.isActive && injector.live.isEmpty, "A broken pinch must cancel its surviving finger")
        let trackpad = TrackpadGestures(injector: injector) { ScreenMetrics() }
        injector.moves = 0
        trackpad.magnify(by: 0, phase: 1, at: nil)
        trackpad.rotate(by: 10, phase: 2, at: nil)
        assert(!trackpad.isActive && injector.live.isEmpty, "A broken trackpad pair must cancel completely")
        injector.failOnMove = 0
        trackpad.magnify(by: 0.1, phase: 1, at: nil)
        assert(trackpad.isActive && injector.live.count == 2)
        trackpad.magnify(by: 0, phase: 3, at: nil)
        assert(injector.live.isEmpty)
    }
    print("PASS: both gesture paths recover from either lost finger and can start again")
    exit(0)
}
dispatchMain()
