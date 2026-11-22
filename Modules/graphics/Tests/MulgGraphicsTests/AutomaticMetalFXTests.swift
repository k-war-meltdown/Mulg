import Foundation
@testable import MulgGraphics
import Testing

@Suite("Automatic MetalFX")
struct AutomaticMetalFXTests {
    @Test func staleAndInvalidTimestampsDoNotChangeDecisions() {
        var watch = AutomaticMetalFX(target: 60), clean = AutomaticMetalFX(target: 60)
        _ = watch.record(presentedTime: 0); _ = clean.record(presentedTime: 0)
        var time = 0.0, index = 0, triggered = false
        let intervals = [0.020, 0.028, 0.022, 0.031]
        while time < 78 {
            time += intervals[index % intervals.count]; index += 1
            let stale = watch.record(presentedTime: time - 0.4), invalid = watch.record(presentedTime: .nan)
            #expect(!stale && !invalid)
            let actual = watch.record(presentedTime: time), expected = clean.record(presentedTime: time)
            #expect(actual == expected)
            triggered = triggered || expected
        }
        #expect(triggered)
    }
    /// Presents `seconds` of frames from `start`, cycling through `intervals`; true once it triggers.
    private func run(_ watch: inout AutomaticMetalFX, from start: Double, seconds: Double, intervals: [Double]) -> (Bool, Double) {
        var time = start, index = 0, triggered = false
        while time < start + seconds {
            time += intervals[index % intervals.count]; index += 1
            if watch.record(presentedTime: time) { triggered = true }
        }
        return (triggered, time)
    }

    @Test("Uneven frames below 60 fps for 10 s switch it on, after the first minute only")
    func gpuBoundTriggers() {
        var watch = AutomaticMetalFX(target: 60)
        let uneven = [0.020, 0.028, 0.022, 0.031, 0.019, 0.026]  // about 40 fps, jittery
        let (early, time) = run(&watch, from: 0, seconds: AutomaticMetalFX.settleTime - 1, intervals: uneven)
        #expect(!early)
        #expect(run(&watch, from: time, seconds: 14, intervals: uneven).0)
    }

    @Test("A steady 30 fps cap and a full 60 fps are left alone")
    func capsAndFullRateDoNot() {
        var capped = AutomaticMetalFX(target: 60)
        #expect(!run(&capped, from: 0, seconds: 120, intervals: [1.0 / 30]).0)
        var full = AutomaticMetalFX(target: 60)
        #expect(!run(&full, from: 0, seconds: 120, intervals: [0.016, 0.017, 0.0165]).0)
    }

    @Test("Loading pauses restart the count")
    func pausesReset() {
        var watch = AutomaticMetalFX(target: 60)
        let uneven = [0.020, 0.028, 0.022, 0.031]
        var (_, time) = run(&watch, from: 0, seconds: AutomaticMetalFX.settleTime, intervals: uneven)
        for _ in 0..<4 {
            let result = run(&watch, from: time, seconds: 8, intervals: uneven)
            #expect(!result.0)
            time = result.1 + 1  // a one-second pause
        }
        #expect(AutomaticMetalFX.target(framesPerSecond: 0) == 60)
        #expect(AutomaticMetalFX.target(framesPerSecond: 40) == 40)
    }
}
