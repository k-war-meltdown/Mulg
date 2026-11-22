import Foundation
import CoreGraphics
public struct ScreenMetrics {
    let width: CGFloat = 1000, height: CGFloat = 500
    func contains(_ point: CGPoint) -> Bool { point.x >= 0 && point.y >= 0 && point.x <= width && point.y <= height }
}
enum TouchPhase { case began, moved, ended }
@MainActor protocol TouchInjecting { func touch(_ id: inout Int?, at: CGPoint, phase: TouchPhase); func cancel(_ id: inout Int?, at: CGPoint) }
@MainActor final class Recorder: TouchInjecting {
    var points: [CGPoint] = [], began = 0
    func touch(_ id: inout Int?, at point: CGPoint, phase: TouchPhase) {
        if phase == .began { began += 1; id = began }
        if id != nil { points.append(point) }
        if phase == .ended { id = nil }
    }
    func cancel(_ id: inout Int?, at point: CGPoint) { id = nil }
}
// __PRODUCTION__
Task { @MainActor in
    let recorder = Recorder(), screen = ScreenMetrics()
    let swipe = SwipeAction(injector: recorder) { screen }
    for _ in 0..<16 { swipe.move(from: { CGPoint(x: 500, y: 250) }, dx: 1, dy: 0) }
    swipe.move(from: { CGPoint(x: 500, y: 250) }, dx: 5000, dy: -5000)
    assert(recorder.points.allSatisfy(screen.contains), "A fast swipe after warmup must not leave the surface")
    swipe.move(from: { CGPoint(x: 500, y: 250) }, dx: 1, dy: 0)
    assert(recorder.began == 2)
    swipe.liftOff(cancelled: true)
    let count = recorder.began
    swipe.move(from: { CGPoint(x: CGFloat.nan, y: 250) }, dx: 1, dy: 0)
    assert(recorder.began == count)
    print("PASS: fast camera swipes stay inside the surface and restart at the next edge")
    exit(0)
}
dispatchMain()
