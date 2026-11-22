import CoreGraphics
import Foundation
import Testing
import MulgContracts
@testable import MulgControls

@Suite("Runtime contact ownership") @MainActor
struct RuntimeInputRegressionTests {
    @Test("Cancelling a calibration request stops its owned sweep immediately")
    func parentCancellationStopsSweep() async {
        let injector = RecordingInjector()
        let zoom = PinchZoom(injector: injector) { injector.screenMetrics }
        let request = Task { await zoom.sweep(outward: true, gestures: 1) }
        while !zoom.isActive { await Task.yield() }
        let moves = injector.events.filter { $0.phase == .moved }.count
        request.cancel()
        await request.value
        #expect(!zoom.isActive)
        #expect(injector.events.filter { $0.phase == .moved }.count == moves)
    }

    @Test("Cancelled calibration cannot lift a newer scroll pinch")
    func replacedSweepDoesNotLiftNewContacts() async throws {
        let injector = RecordingInjector()
        let zoom = PinchZoom(injector: injector) { injector.screenMetrics }
        let sweep = Task { await zoom.sweep(outward: true, gestures: 2) }
        while !zoom.isActive { await Task.yield() }
        zoom.cancel()
        zoom.scroll(10)
        let began = injector.events.filter { $0.phase == .began }.count
        await sweep.value
        #expect(zoom.isActive)
        #expect(injector.events.filter { $0.phase == .began }.count == began)
        zoom.cancel()
    }

    @Test("Cancelling a frame wait resumes it without another game frame")
    func cancelledFrameWaitIsRemoved() async throws {
        let ticker = FrameTicker()
        let wait = Task { await ticker.wait(frames: 100, timeout: .seconds(5)) }
        while ticker.pendingWaiters == 0 { await Task.yield() }
        wait.cancel()
        for _ in 0..<100 where ticker.pendingWaiters > 0 { await Task.yield() }
        #expect(ticker.pendingWaiters == 0)
        // Keep a failed test bounded as well.
        for _ in 0..<100 { ticker.tick() }
        await wait.value
    }

    @Test("Simultaneous magnification and rotation share two contacts until both end")
    func combinedTrackpadGestures() {
        let injector = RecordingInjector()
        let gestures = TrackpadGestures(injector: injector) { injector.screenMetrics }
        gestures.magnify(by: 0, phase: 1, at: nil)
        gestures.rotate(by: 0, phase: 1, at: nil)
        #expect(injector.events.filter { $0.phase == .began }.count == 2)
        gestures.magnify(by: 0.1, phase: 2, at: nil)
        gestures.rotate(by: 10, phase: 2, at: nil)
        gestures.rotate(by: 0, phase: 3, at: nil)
        #expect(gestures.isActive)
        gestures.magnify(by: 0, phase: 3, at: nil)
        #expect(!gestures.isActive)
        #expect(injector.events.filter { $0.phase == .ended }.count == 2)
    }

    @Test("The initial trackpad event's nonzero magnification and rotation are applied")
    func initialTrackpadDelta() {
        let injector = RecordingInjector()
        let gestures = TrackpadGestures(injector: injector) { injector.screenMetrics }
        gestures.magnify(by: 0.5, phase: 1, at: nil)
        #expect(abs(gestures.fingerPoint(0).x - 590) < 0.001)
        gestures.cancel()
        gestures.rotate(by: 90, phase: 1, at: nil)
        #expect(abs(gestures.fingerPoint(0).x - 500) < 0.001)
        #expect(abs(gestures.fingerPoint(0).y - 190) < 0.001)
        gestures.cancel()
    }

    @Test("Outside-window points and fullscreen letterbox bars never become game clicks")
    func cursorBounds() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let screen = CGSize(width: 1000, height: 600)
        for point in [CGPoint(x: -1, y: 300), CGPoint(x: 1001, y: 300), CGPoint(x: 500, y: -1),
                      CGPoint(x: CGFloat.nan, y: 300)] {
            #expect(CursorMapping.gamePoint(mouse: point, window: window, screen: screen,
                                           fullscreen: false, resizable: false) == nil)
        }
        #expect(CursorMapping.gamePoint(mouse: CGPoint(x: 500, y: 1), window: window,
            screen: CGSize(width: 1600, height: 800), fullscreen: true, resizable: false) == nil)
        #expect(CursorMapping.gamePoint(mouse: CGPoint(x: 500, y: 300), window: window,
            screen: screen, fullscreen: false, resizable: false) == CGPoint(x: 500, y: 300))
    }

    @Test("A short begin timeout does not fail a longer waiter for the same touch")
    func beginDeadlinesAreIndependent() async throws {
        let waiters = TouchBeginWaiters()
        let short = Task { await waiters.wait(7, timeout: .milliseconds(10)) }
        let long = Task { await waiters.wait(7, timeout: .seconds(2)) }
        #expect(await short.value == false)
        waiters.resolve(7, delivered: true)
        #expect(await long.value == true)
        #expect(waiters.ids.isEmpty)
    }

    @Test("Cancellation removes only that touch begin waiter")
    func beginCancellationIsIndependent() async {
        let waiters = TouchBeginWaiters()
        let cancelled = Task { await waiters.wait(8, timeout: .seconds(2)) }
        let other = Task { await waiters.wait(8, timeout: .seconds(2)) }
        while waiters.ids.isEmpty { await Task.yield() }
        cancelled.cancel()
        #expect(await cancelled.value == false)
        waiters.resolve(8, delivered: true)
        #expect(await other.value == true)
    }
}
