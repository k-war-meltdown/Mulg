import Foundation
import MulgContracts
@testable import MulgDiagnostics
import Testing

@Suite("Diagnostics statistics")
struct StatisticsTests {
    @Test("The ring keeps the newest values in order")
    func ring() {
        var ring = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { ring.append(value) }
        #expect(Array(ring) == [3, 4, 5])
        #expect(ring.last == 5)
        ring.removeAll()
        #expect(ring.isEmpty)
        #expect(ring.last == nil)
    }

    @Test("Steady 120 FPS with one hitch")
    func frames() throws {
        var stats = FrameStats()
        var time = 100.0
        stats.record(presentedTime: time)
        for index in 1...240 {
            time += index == 60 ? 0.05 : 1.0 / 120
            stats.record(presentedTime: time)
        }
        let summary = try #require(stats.summary())
        #expect(summary.frames == 240)
        #expect(summary.onePercentLowFPS < 40)
        #expect(abs(summary.worstFrameTimeMs - 50) < 0.01)
        #expect(summary.averageFPS > 100 && summary.averageFPS < 120)
        let recent = try #require(stats.recentFPS())
        #expect(abs(recent - 120) < 1)
    }

    @Test("A pause is not a slow frame, and time going backwards is ignored")
    func pauses() throws {
        var stats = FrameStats()
        stats.record(presentedTime: 1)
        stats.record(presentedTime: 1 + 1.0 / 60)
        stats.record(presentedTime: 10)
        stats.record(presentedTime: 5)
        stats.record(presentedTime: 10 + 1.0 / 60)
        let summary = try #require(stats.summary())
        #expect(summary.frames == 2)
        #expect(abs(summary.averageFPS - 60) < 0.5)
    }

    @Test("Inputs pair with the next frame presented after them")
    func latency() throws {
        var tracker = LatencyTracker()
        tracker.inputDelivered(arrival: 1.000, injected: 1.0002)
        tracker.inputDelivered(arrival: 1.010, injected: 1.0101)
        #expect(tracker.framePresented(at: 1.005).count == 1)
        let second = tracker.framePresented(at: 1.030)
        #expect(second.count == 1)
        #expect(abs(second[0].inputToPresentMs - 20) < 0.001)
        let summary = try #require(tracker.summary())
        #expect(summary.samples == 2)
        #expect(abs(summary.medianProcessingMs - 0.1) < 0.2)
    }

    @Test("Inputs with no frame for a long time are dropped")
    func staleInputs() {
        var tracker = LatencyTracker()
        tracker.inputDelivered(arrival: 1, injected: 5)
        #expect(tracker.framePresented(at: 2).isEmpty)
        tracker.inputDelivered(arrival: 8.4, injected: 8.5)
        #expect(tracker.framePresented(at: 9).count == 1)
        #expect(tracker.summary()?.samples == 1)
    }

    @Test func machClockMatchesNanoseconds() {
        #expect(MachClock.seconds(0) == 0)
        #expect(MachClock.seconds(1_000_000_000) > 0)
    }
}

@Suite("Performance overlay text")
struct OverlayTextTests {
    @Test("Before any frame, it says it is waiting")
    func waiting() {
        #expect(OverlayText.lines(OverlayText.State()) == ["— FPS (waiting for frames)", "MetalFX off"])
    }

    @Test("FPS, 1% low, frame times, latency, refresh and MetalFX")
    func full() {
        let frames = FrameStats.Summary(frames: 1200, averageFPS: 119.6, onePercentLowFPS: 98.4, averageFrameTimeMs: 8.36,
                                        worstFrameTimeMs: 14.2, frameTimeDeviationMs: 0.4)
        let latency = LatencyTracker.Summary(samples: 50, medianMs: 21.2, p95Ms: 27.9, worstMs: 40, medianProcessingMs: 0.05)
        let lines = OverlayText.lines(OverlayText.State(recentFPS: 119.8, frames: frames, latency: latency,
                                                        metalFX: .balanced, refreshRate: 120))
        #expect(lines[0] == "120 FPS · 1% low 98")
        #expect(lines[1] == "8.4 ms · worst 14.2 ms · ±0.4")
        #expect(lines[2] == "Input→next present ≈21 ms (p95 28)")
        #expect(lines[3] == "120 Hz · MetalFX \(MetalFXPreset.balanced.label)")
    }

    @Test("A hot Mac shows on the last line")
    func hot() {
        #expect(OverlayText.lines(OverlayText.State(hot: true)).last == "MetalFX off · Mac hot")
    }
}
