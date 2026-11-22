import Foundation
import MulgContracts

/// The rules of Camera reach calibration, apart from memory and UI so they can be tested.
///
/// Calibration asks the player to zoom all the way out and in twice. A camera's zoom distance is
/// clamped to the game's limits, so at each end it holds exactly the same value every time; the
/// four steps keep only values that do exactly that. The limits themselves sit side by side in
/// the game's camera settings, which is how they are found and raised.
nonisolated enum CameraCalibrationPlan {
    /// The four steps, in order. Each is confirmed with the calibration hotkey.
    enum Step: Int, CaseIterable, Sendable {
        case farthest = 1, nearest, farthestAgain, nearestAgain

        /// What the player does before pressing the hotkey for this step.
        var instruction: String {
            switch self {
            case .farthest, .farthestAgain: "Zoom the camera all the way OUT"
            case .nearest, .nearestAgain: "Zoom the camera all the way IN"
            }
        }

        var next: Step? { Step(rawValue: rawValue + 1) }

        /// Zoomed all the way out at this step (otherwise all the way in).
        var zoomsOut: Bool { self == .farthest || self == .farthestAgain }
    }

    /// Survivors that share both end values: one camera distance (and its smoothed copies).
    struct Group: Sendable, Equatable {
        private let farthestMasked: UInt32
        private let nearestMasked: UInt32
        let addresses: [UInt64]

        init(farthestBits: UInt32, nearestBits: UInt32, addresses: [UInt64]) {
            farthestMasked = farthestBits ^ CameraCalibration.mask
            nearestMasked = nearestBits ^ CameraCalibration.mask
            self.addresses = addresses
        }

        var farthestBits: UInt32 { farthestMasked ^ CameraCalibration.mask }
        var nearestBits: UInt32 { nearestMasked ^ CameraCalibration.mask }
        var farthest: Float { Float(bitPattern: farthestBits) }
        var nearest: Float { Float(bitPattern: nearestBits) }
    }

    /// At most this many groups are tried, the most specific (fewest copies) first.
    static let maximumGroups = 8
    /// Addresses watched per group while checking that the raised limit works.
    static let maximumWatched = 16

    /// Limits a camera could have: finite, the farthest clearly beyond the nearest. A nearest of
    /// exactly 0 is a normalised zoom level (0 all the way in, up to 1 or a small number out).
    static func isPlausible(farthest: Float, nearest: Float) -> Bool {
        guard farthest.isFinite, nearest.isFinite, farthest <= CameraMemory.searchRange.upperBound else { return false }
        if nearest == 0 { return farthest > 0 && farthest <= 4 }
        return nearest >= 1e-6 && farthest >= nearest * CameraMemory.minimumZoomRatio
    }

    /// The survivors grouped by their two end values; implausible ones dropped. Fewest addresses
    /// first: a value held once is the camera's own setting; many copies are usually derived data
    /// (matrices, caches) the game rewrites every frame. Ties keep the order found.
    static func groups(_ survivors: [CameraMemory.Survivor]) -> [Group] {
        var byLimits: [UInt64: [UInt64]] = [:]
        var order: [UInt64] = []
        for survivor in survivors {
            let far = Float(bitPattern: survivor.farthestBits), near = Float(bitPattern: survivor.nearestBits)
            guard isPlausible(farthest: far, nearest: near) else { continue }
            // Keyed masked, like every other copy of these values in Mulg's memory.
            let key = UInt64(survivor.farthestBits ^ CameraCalibration.mask) << 32
                | UInt64(survivor.nearestBits ^ CameraCalibration.mask)
            if byLimits[key] == nil { order.append(key) }
            byLimits[key, default: []].append(survivor.address)
        }
        return order.enumerated()
            .sorted { lhs, rhs in
                let left = byLimits[lhs.element]!.count, right = byLimits[rhs.element]!.count
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .prefix(maximumGroups)
            .map { _, key in
                Group(farthestBits: UInt32(truncatingIfNeeded: key >> 32) ^ CameraCalibration.mask,
                      nearestBits: UInt32(truncatingIfNeeded: key) ^ CameraCalibration.mask,
                      addresses: Array(byLimits[key]!.prefix(maximumWatched)))
            }
    }

    /// A hold trial worked when another camera value passed its own limit for half the ticks (the
    /// camera moved), or the held value stayed past the limit and the game eased it (it reads it).
    static func holdWorked(_ statistics: CameraHold.Statistics, watched: Bool) -> Bool {
        // 40, not 100: macOS stretches a throttled process's 4 ms sleeps to about 50 ms, so a 2.5 s trial
        // can see fewer than 100 ticks while the hold works (2026-10-10, measured under load).
        guard statistics.ticks >= 40 else { return false }
        if watched && statistics.watchedPast * 2 >= statistics.ticks { return true }
        return statistics.heldPast * 10 >= statistics.ticks * 8 && statistics.eased > 0
    }

    /// The value to hold for `group`. A normalised zoom level (nearest 0) maps linearly onto a
    /// distance group's range, so it is extended to where that distance reaches `reach` times
    /// its limit; anything else is its limit times `reach`.
    /// Below this a zoomed-in end counts as the 0 of a normalised zoom level.
    static let levelZero: Float = 1e-3

    static func heldBits(_ group: Group, distance: Group?, reach: Double) -> UInt32 {
        // Small normal floats can be an eased zoom level. Subnormal bit patterns
        // are rejected before grouping because they can be integer fields.
        guard group.nearest < Self.levelZero, group.farthest <= 4, let distance, distance.farthest > distance.nearest else {
            return raisedBits(farthestBits: group.farthestBits, reach: reach)
        }
        let factor = Float(CameraSettings.clampedReach(reach))
        let level = group.farthest * (distance.farthest * factor - distance.nearest) / (distance.farthest - distance.nearest)
        return level.isFinite && level > group.farthest ? level.bitPattern : raisedBits(farthestBits: group.farthestBits, reach: reach)
    }

    /// The farthest limit raised by `reach`, as a float bit pattern.
    static func raisedBits(farthestBits: UInt32, reach: Double) -> UInt32 {
        let raised = Float(bitPattern: farthestBits) * Float(CameraSettings.clampedReach(reach))
        return raised.isFinite ? raised.bitPattern : farthestBits
    }

    /// Whether a watched distance shows the camera went past the game's own limit.
    static func passedLimit(_ value: Float, farthest: Float) -> Bool {
        value.isFinite && farthest.isFinite && farthest > 0 &&
            value > farthest * 1.01 && value <= farthest * Float(CameraSettings.clampedReach(3))
    }

    /// The distinct offsets of the pairs raised, for the saved calibration.
    static func offsets(_ pairs: [CameraMemory.Pair]) -> [Int] {
        Array(Set(pairs.map { Int($0.offset) })).sorted()
    }

    /// A later launch's search is trusted only when it finds about as many pairs as calibration did.
    static func acceptsSearch(found: Int, calibrated: Int) -> Bool {
        found > 0 && found <= max(8, calibrated * 4)
    }

    /// Seconds after start-up (or after the raised limits disappeared) to look for them again.
    /// Each search reads the game's resident memory once (a few seconds on a utility thread, paced),
    /// so they are few and far apart.
    static let searchDelays: [Double] = [30, 90, 240, 600]
}
