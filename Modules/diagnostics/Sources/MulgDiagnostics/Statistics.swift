import Foundation

/// A fixed-size ring of values: the newest `capacity` are kept, the oldest dropped, with no
/// allocation after the first fill. Frame and input samples arrive up to hundreds of times a
/// second, so nothing on that path may copy or shift arrays.
public struct RingBuffer<Element>: Sequence {
    private var storage: [Element] = []
    private var next = 0
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[next] = element
        }
        next = (next + 1) % capacity
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        next = 0
    }

    /// Oldest first.
    public func makeIterator() -> AnyIterator<Element> {
        let ordered = storage.count < capacity ? storage : Array(storage[next...] + storage[..<next])
        return AnyIterator(ordered.makeIterator())
    }

    public var last: Element? {
        guard !storage.isEmpty else { return nil }
        // While filling, `next` equals `count`; once full it points at the oldest value.
        return storage[(next - 1 + capacity) % capacity]
    }
}

extension RingBuffer: Sendable where Element: Sendable {}

enum Percentile {
    /// The value below which `fraction` of the sorted values fall (nearest rank).
    static func of(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

/// Frame rate and pacing from the game's presentation times (PLAN.md §8: "average FPS and
/// 1% lows, frame-pacing stability").
public struct FrameStats: Sendable {
    public struct Summary: Sendable, Equatable, Codable {
        public var frames: Int
        public var averageFPS: Double
        /// The frame rate of the slowest 1% of frames: what a player feels as stutter.
        public var onePercentLowFPS: Double
        public var averageFrameTimeMs: Double
        public var worstFrameTimeMs: Double
        /// Standard deviation of frame times: low means even pacing.
        public var frameTimeDeviationMs: Double
    }

    private struct Interval: Sendable {
        let end: Double
        let seconds: Double
    }

    /// Seconds of history the summary covers.
    public let window: Double
    /// A longer gap is a pause (hidden window, loading screen), not a slow frame.
    public let pauseThreshold: Double
    private var intervals: RingBuffer<Interval>
    private var lastPresent: Double?

    public init(window: Double = 10, pauseThreshold: Double = 2, maximumFrameRate: Int = 240) {
        self.window = window
        self.pauseThreshold = pauseThreshold
        intervals = RingBuffer(capacity: max(60, Int(window) * maximumFrameRate))
    }

    public mutating func record(presentedTime: Double) {
        defer { lastPresent = max(lastPresent ?? presentedTime, presentedTime) }
        guard let lastPresent, presentedTime > lastPresent else { return }
        let seconds = presentedTime - lastPresent
        guard seconds < pauseThreshold else { return }
        intervals.append(Interval(end: presentedTime, seconds: seconds))
    }

    public mutating func reset() {
        intervals.removeAll()
        lastPresent = nil
    }

    /// Frames per second over the last `seconds` (the overlay's live number).
    public func recentFPS(over seconds: Double = 1) -> Double? {
        guard let latest = intervals.last?.end else { return nil }
        let recent = intervals.filter { $0.end > latest - seconds }
        let total = recent.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return nil }
        return Double(recent.count) / total
    }

    public func summary() -> Summary? {
        guard let latest = intervals.last?.end else { return nil }
        let times = intervals.filter { $0.end > latest - window }.map(\.seconds)
        guard !times.isEmpty else { return nil }
        let total = times.reduce(0, +)
        let mean = total / Double(times.count)
        let slowest = times.sorted(by: >)
        let slowCount = max(1, times.count / 100)
        let slowMean = slowest.prefix(slowCount).reduce(0, +) / Double(slowCount)
        let variance = times.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(times.count)
        return Summary(frames: times.count,
                       averageFPS: 1 / mean,
                       onePercentLowFPS: 1 / slowMean,
                       averageFrameTimeMs: mean * 1000,
                       worstFrameTimeMs: (slowest.first ?? 0) * 1000,
                       frameTimeDeviationMs: variance.squareRoot() * 1000)
    }
}

/// Input-to-present time (PLAN.md §6.1): for every input the controls module delivered, the
/// time from its arrival from macOS to the next presented frame, and the part of that spent
/// in Mulg before the input reached the game.
public struct LatencyTracker: Sendable {
    public struct Sample: Sendable, Equatable, Codable {
        /// Arrival from macOS to injection into the game: Mulg's own cost (target < 0.5 ms).
        public var processingMs: Double
        /// Estimate to the next presentation. It does not prove the frame contains this input.
        public var inputToPresentMs: Double
    }

    public struct Summary: Sendable, Equatable, Codable {
        public var samples: Int
        public var medianMs: Double
        public var p95Ms: Double
        public var worstMs: Double
        public var medianProcessingMs: Double
    }

    private struct Pending: Sendable {
        let arrival: Double
        let injected: Double
    }

    private var pending: [Pending] = []
    private var samples: RingBuffer<Sample>
    /// An input with no frame after this long is dropped (the game was not drawing).
    public let staleAfter: Double

    public init(capacity: Int = 2_000, staleAfter: Double = 1) {
        samples = RingBuffer(capacity: capacity)
        self.staleAfter = staleAfter
    }

    /// Times in seconds, in the `CACurrentMediaTime()` clock.
    public mutating func inputDelivered(arrival: Double, injected: Double) {
        if pending.count >= 256 {
            pending.removeFirst(pending.count - 255)
        }
        pending.append(Pending(arrival: arrival, injected: injected))
    }

    /// Pairs every waiting input injected before `presentedTime` with this frame. Returns the
    /// new samples, for logging.
    @discardableResult
    public mutating func framePresented(at presentedTime: Double) -> [Sample] {
        guard !pending.isEmpty else { return [] }
        var made: [Sample] = []
        pending.removeAll { input in
            guard input.injected <= presentedTime else { return false }
            // A frame long after the input means the game was not drawing; no sample.
            if presentedTime - input.injected <= staleAfter {
                let sample = Sample(processingMs: (input.injected - input.arrival) * 1000,
                                    inputToPresentMs: (presentedTime - input.arrival) * 1000)
                samples.append(sample)
                made.append(sample)
            }
            return true
        }
        return made
    }

    public var latest: Sample? { samples.last }

    public func summary() -> Summary? {
        let totals = samples.map(\.inputToPresentMs).sorted()
        let processing = samples.map(\.processingMs).sorted()
        guard let median = Percentile.of(totals, 0.5), let p95 = Percentile.of(totals, 0.95),
              let worst = totals.last, let medianProcessing = Percentile.of(processing, 0.5) else { return nil }
        return Summary(samples: totals.count, medianMs: median, p95Ms: p95, worstMs: worst,
                       medianProcessingMs: medianProcessing)
    }
}

/// Converts mach absolute time, which `InputDelivered` carries, to seconds in the same clock
/// as `CACurrentMediaTime()` and Metal's presented times.
public enum MachClock {
    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(max(1, info.denom)))
    }()

    public static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * timebase.numer / timebase.denom / 1_000_000_000
    }
}
