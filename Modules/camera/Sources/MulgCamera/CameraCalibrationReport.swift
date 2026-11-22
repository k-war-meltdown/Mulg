import Foundation

/// What one calibration found and tried, written to the game's diagnostics folder as
/// camera-calibration.json, so a failed calibration can be understood without guessing.
/// Values are stored as Double: their bit patterns differ from the game's 32-bit floats, so a
/// later search never finds this report in Mulg's own memory.
struct CalibrationReport: Codable, Sendable {
    struct Group: Codable, Sendable {
        var farthest: Double
        var nearest: Double
        /// How many places held exactly these values.
        var copies: Int
        /// VM tag and region size of the first few.
        var regions: [String]
        /// Limit pairs found beside them; nil when none could be searched (too many, or nearest 0).
        var pairs: Int?
    }

    struct Trial: Codable, Sendable {
        var kind: String
        var farthest: Double
        var writes: Int
        var passed: Bool
        /// The value seen past the limit (pairs trials).
        var seen: Double?
        var ticks: Int?
        var heldPast: Int?
        var eased: Int?
        var watchedPast: Int?

        init(kind: String, farthest: Double, writes: Int, passed: Bool, seen: Double?,
             statistics: CameraHold.Statistics? = nil) {
            self.kind = kind
            self.farthest = farthest
            self.writes = writes
            self.passed = passed
            self.seen = seen
            ticks = statistics?.ticks
            heldPast = statistics?.heldPast
            eased = statistics?.eased
            watchedPast = statistics?.watchedPast
        }
    }

    static let fileName = "camera-calibration.json"

    var gameVersion: String
    var started: Date = .now
    var automatic: Bool
    /// Values left after each of the four steps.
    var steps: [UInt64] = []
    var groups: [Group] = []
    var trials: [Trial] = []
    var result = "running"
}
