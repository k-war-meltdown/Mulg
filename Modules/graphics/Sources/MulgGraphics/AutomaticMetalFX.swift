import Foundation

/// The decision behind `metalFX.automatic`: the game is GPU-bound when its frame rate stays below
/// the target for `slowBuckets` two-second spans in a row with uneven pacing. A steady rate below
/// the target is the game's own cap (30 fps, say), not a GPU short of time, and is left alone.
/// Loading pauses reset the count, and nothing is judged during the first `settleTime` seconds.
nonisolated struct AutomaticMetalFX: Sendable {
    static let bucket: Double = 2
    static let slowBuckets = 5
    static let settleTime: Double = 60
    /// A longer gap is a pause (loading, a hidden window), not a slow frame.
    static let pause: Double = 0.5

    /// Frames per second the game should reach.
    var target: Double {
        didSet {
            guard target != oldValue else { return }
            // A different cap changes what "slow" means. Start a new observation
            // bucket rather than inheriting failures measured against the old cap.
            bucketStart = nil
            last = nil
            intervals.removeAll(keepingCapacity: true)
            slowInARow = 0
        }
    }
    private var started: Double?
    private var last: Double?
    private var bucketStart: Double?
    private var intervals: [Double] = []
    private var slowInARow = 0

    init(target: Double) {
        self.target = target
    }

    /// The frame limit when there is one, else 60: iPad games cap themselves at 60 even on a
    /// faster display, which is not a GPU shortfall.
    static func target(framesPerSecond: Int) -> Double {
        framesPerSecond > 0 ? Double(framesPerSecond) : 60
    }

    /// Feeds one presented frame; true once the game has been GPU-bound long enough.
    mutating func record(presentedTime time: Double) -> Bool {
        guard time.isFinite, last.map({ time > $0 }) ?? true else { return false }
        if started == nil { started = time }
        defer { last = time }
        guard let last, time > last else { return false }
        let interval = time - last
        guard interval < Self.pause else {
            bucketStart = nil; intervals.removeAll(keepingCapacity: true); slowInARow = 0
            return false
        }
        guard let started, time - started >= Self.settleTime else { return false }
        let start = bucketStart ?? last
        bucketStart = start
        intervals.append(interval)
        guard time - start >= Self.bucket else { return false }
        slowInARow = Self.isSlow(intervals, target: target) ? slowInARow + 1 : 0
        bucketStart = time
        intervals.removeAll(keepingCapacity: true)
        return slowInARow >= Self.slowBuckets
    }

    /// Below 90% of the target and uneven: fewer than 80% of the frames within 8% of the median.
    static func isSlow(_ intervals: [Double], target: Double) -> Bool {
        guard !intervals.isEmpty, target > 0 else { return false }
        let total = intervals.reduce(0, +)
        guard Double(intervals.count) / total < target * 0.9 else { return false }
        let median = intervals.sorted()[intervals.count / 2]
        let steady = intervals.filter { abs($0 - median) <= median * 0.08 }.count
        return Double(steady) < Double(intervals.count) * 0.8
    }
}
