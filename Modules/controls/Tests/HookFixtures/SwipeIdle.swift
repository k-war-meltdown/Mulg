import CoreGraphics
import Foundation

public struct ScreenMetrics {
    let width: CGFloat = 1000, height: CGFloat = 500
    func contains(_ point: CGPoint) -> Bool { (0...width).contains(point.x) && (0...height).contains(point.y) }
}
enum TouchPhase { case began, moved, ended }
@MainActor protocol TouchInjecting {
    func touch(_ id: inout Int?, at: CGPoint, phase: TouchPhase)
    func cancel(_ id: inout Int?, at: CGPoint)
}
@MainActor final class Recorder: TouchInjecting {
    var ended = 0
    func touch(_ id: inout Int?, at point: CGPoint, phase: TouchPhase) {
        if phase == .began { id = 1 }
        if phase == .ended, id != nil { ended += 1; id = nil }
    }
    func cancel(_ id: inout Int?, at point: CGPoint) { id = nil }
}
@MainActor enum SwipeTestClock {
    static var pending: [CheckedContinuation<Void, Never>] = []
    static func wait() async { await withCheckedContinuation { pending.append($0) } }
    static func tick() { if !pending.isEmpty { pending.removeFirst().resume() } }
}
// __PRODUCTION__
Task { @MainActor in
    let recorder = Recorder()
    // Keep one recorder for the entire replaced-contact sequence.
    let action = SwipeAction(injector: recorder) { ScreenMetrics() }
    action.move(from: { CGPoint(x: 500, y: 250) }, dx: 1, dy: 0)
    while SwipeTestClock.pending.isEmpty { await Task.yield() }
    action.liftOff(cancelled: true)
    action.move(from: { CGPoint(x: 500, y: 250) }, dx: 1, dy: 0)
    while SwipeTestClock.pending.count < 2 { await Task.yield() }
    SwipeTestClock.tick() // Resume the cancelled task after its replacement has begun.
    for _ in 0..<10 { await Task.yield() }
    for _ in 0..<5 {
        SwipeTestClock.tick()
        for _ in 0..<10 { await Task.yield() }
    }
    assert(recorder.ended == 0, "Cancelled timer shortened the next swipe's lifetime")
    SwipeTestClock.tick()
    for _ in 0..<10 { await Task.yield() }
    assert(recorder.ended == 1, "The current timer must still end the idle swipe")
    exit(0)
}
dispatchMain()
