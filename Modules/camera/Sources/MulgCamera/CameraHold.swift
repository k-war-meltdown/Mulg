import Foundation
import os

/// Holds a camera distance past the game's limit for games that recompute it every frame.
///
/// A small background thread writes the raised value every 4 ms (more often than any frame) while
/// the player is zoomed all the way out, and stops the moment the player zooms in, so zooming in
/// from beyond the limit always works. It reads and writes with compare-and-swap through
/// CameraMemory, never on the game's main thread, and costs a few microseconds per tick.
///
/// It also measures whether holding helps: how often the held values were found past the limit
/// before being written again, and how often other camera values the game derives (`watched`)
/// went past their own limits, which proves the camera itself moved.
nonisolated final class CameraHold: @unchecked Sendable {
    struct Target: Sendable {
        let addresses: [UInt64]
        let farthestBits: UInt32
        var raisedBits: UInt32
        /// Other values that followed the zoom, with their own zoomed-out values.
        let watched: [(address: UInt64, farthestBits: UInt32)]
    }

    struct Statistics: Sendable, Equatable {
        var ticks = 0
        /// Ticks where a held value was still past the limit when read (the game kept or eased it).
        var heldPast = 0
        /// Ticks where a held value was strictly between the limit and the raised value (the game eases).
        var eased = 0
        /// Ticks where a watched value was past its own limit (the camera really moved).
        var watchedPast = 0
    }

    private struct State {
        var target: Target?
        /// Writing now: the player is zoomed all the way out (or a trial forces it).
        var extending = false
        var forced = false
        /// The player's last zoom was outward (or there was none yet).
        var lastOutward = true
        var statistics = Statistics()
        var running = false
        /// Each start of the thread; an older thread stops at its next tick.
        var generation = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    static let interval: useconds_t = 4_000

    /// Starts holding `target`. `force` writes from the first tick (a calibration trial, after Mulg
    /// zoomed out itself); otherwise writing starts when the game's value reaches its limit.
    func start(_ target: Target, force: Bool = false) {
        let launch = state.withLock { state -> Int? in
            state.target = target
            state.forced = force
            state.extending = force
            state.statistics = Statistics()
            state.running = true
            state.generation &+= 1
            return state.generation
        }
        guard let generation = launch else { return }
        Thread.detachNewThread { [self] in
            Thread.current.qualityOfService = .utility
            Thread.current.name = "io.mulg.camera.hold"
            while tick(generation) { usleep(Self.interval) }
        }
    }

    /// Stops writing and returns what was measured. The game's own value comes back by itself on
    /// its next frame; callers restore anything the game does not recompute.
    @discardableResult
    func stop() -> Statistics {
        state.withLock { state in
            state.target = nil
            state.running = false
            return state.statistics
        }
    }

    var statistics: Statistics { state.withLock { $0.statistics } }

    func setRaised(_ bits: UInt32) {
        state.withLock { $0.target?.raisedBits = bits }
    }

    /// The player zoomed: inward stops extending at once; outward lets it resume at the limit.
    func playerZoomed(outward: Bool) {
        state.withLock { state in
            state.lastOutward = outward
            if !outward && !state.forced { state.extending = false }
        }
    }

    /// One tick; false once stopped.
    private func tick(_ generation: Int) -> Bool {
        guard let (target, extending) = state.withLock({ state -> (Target, Bool)? in
            guard state.running, state.generation == generation, let target = state.target else { return nil }
            return (target, state.extending)
        }) else { return false }
        let farthest = Float(bitPattern: target.farthestBits), raised = Float(bitPattern: target.raisedBits)
        var atLimit = false, past = false, between = false
        for address in target.addresses {
            guard let bits = CameraMemory.read(address) else { continue }
            let value = Float(bitPattern: bits)
            if bits == target.farthestBits { atLimit = true }
            if CameraCalibrationPlan.passedLimit(value, farthest: farthest) {
                past = true
                if value < raised * 0.999 { between = true }
            }
            if extending, bits != target.raisedBits, value >= farthest * 0.999, value <= raised {
                // Under the lock: once stop() returns no write follows, so a restore right after it stays.
                state.withLock { state in
                    guard state.running, state.generation == generation, state.extending,
                          let current = state.target else { return }
                    _ = CameraMemory.swap(address, expected: bits, replacement: current.raisedBits)
                }
            }
        }
        let reachedLimit = atLimit, wasPast = past, wasBetween = between
        let watchedPast = target.watched.contains { item in
            CameraMemory.read(item.address).map {
                CameraCalibrationPlan.passedLimit(Float(bitPattern: $0), farthest: Float(bitPattern: item.farthestBits))
            } ?? false
        }
        state.withLock { state in
            guard state.running, state.generation == generation else { return }
            if !state.extending, state.lastOutward, reachedLimit { state.extending = true }
            if state.extending {
                state.statistics.ticks += 1
                if wasPast { state.statistics.heldPast += 1 }
                if wasBetween { state.statistics.eased += 1 }
                if watchedPast { state.statistics.watchedPast += 1 }
            }
        }
        return true
    }

    deinit { stop() }
}
