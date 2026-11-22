import Foundation

// MARK: - camera (Camera reach)

/// Camera reach: lets the camera zoom out farther than the game allows.
///
/// The camera module finds the game's zoom limit in memory by watching which values follow the
/// player zooming in and out (a calibration), then raises it. Nothing depends on the game's code,
/// so a game update does not break it; if an update changes the limit itself, calibrating again
/// finds the new one.
public struct CameraSettings: Codable, Sendable, Equatable {
    public static let reachRange: ClosedRange<Double> = 1.1...3.0

    /// Off by default: it changes the game's own memory (see the warning in the settings).
    public var extendedReach: Bool = false
    /// How much farther than the game's limit the camera may go: 1.6 is 60 % farther.
    public var reach: Double = 1.6
    /// Starts calibration and confirms each of its steps in the game. No ⌘ or ⌥: those belong to
    /// menu shortcuts and the cursor key, which caught build 892's ⌥⌘Z before Mulg saw it.
    public var calibrateHotkey: String = Self.defaultHotkey
    public static let defaultHotkey = "shift+9"

    public init() {}

    enum CodingKeys: String, CodingKey { case extendedReach, reach, calibrateHotkey }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CameraSettings()
        extendedReach = try c.value(.extendedReach, default: d.extendedReach)
        reach = Self.clampedReach(try c.value(.reach, default: d.reach))
        let hotkey = try c.value(.calibrateHotkey, default: d.calibrateHotkey)
        // Build 892's default never reached Mulg; move everyone who kept it to the new one.
        calibrateHotkey = hotkey == "option+command+Z" ? Self.defaultHotkey : hotkey
    }

    public static func clampedReach(_ value: Double) -> Double {
        value.isFinite ? min(max(value, reachRange.lowerBound), reachRange.upperBound) : CameraSettings().reach
    }
}

/// What calibration found, saved per game so later launches apply it without asking.
///
/// The limits are stored as the exact bit patterns of the game's 32-bit floats: the search
/// matches bits, not approximate values.
public struct CameraCalibration: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int = Self.currentVersion
    /// The game's farthest zoom distance (its limit) and nearest one, as float bit patterns.
    ///
    /// Held masked in memory: the camera module searches the game's memory for exactly these two
    /// values close together, and must never find (and write to) its own copy.
    private var farthestMasked: UInt32
    private var nearestMasked: UInt32
    public var farthestBits: UInt32 { farthestMasked ^ Self.mask }
    public var nearestBits: UInt32 { nearestMasked ^ Self.mask }
    public static let mask: UInt32 = 0xA5C3_5A3C
    /// Byte distance from each farthest limit found to its nearest limit: the shape of the game's
    /// camera settings in memory. Later launches look for exactly these pairs.
    public var offsets: [Int]
    /// How many limit pairs calibration raised; a later search finding far more is ambiguous.
    public var pairs: Int
    /// The game version calibrated, shown in the app and in notices after an update.
    public var gameVersion: String
    public var created: Date

    public init(farthestBits: UInt32, nearestBits: UInt32, offsets: [Int], pairs: Int,
                gameVersion: String, created: Date = .now) {
        farthestMasked = farthestBits ^ Self.mask
        nearestMasked = nearestBits ^ Self.mask
        self.offsets = offsets
        self.pairs = pairs
        self.gameVersion = gameVersion
        self.created = created
    }

    enum CodingKeys: String, CodingKey { case version, farthestBits, nearestBits, offsets, pairs, gameVersion, created }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        farthestMasked = try c.decode(UInt32.self, forKey: .farthestBits) ^ Self.mask
        nearestMasked = try c.decode(UInt32.self, forKey: .nearestBits) ^ Self.mask
        offsets = try c.decode([Int].self, forKey: .offsets)
        pairs = try c.decode(Int.self, forKey: .pairs)
        gameVersion = try c.value(.gameVersion, default: "")
        created = try c.value(.created, default: Date.now)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(farthestBits, forKey: .farthestBits)
        try c.encode(nearestBits, forKey: .nearestBits)
        try c.encode(offsets, forKey: .offsets)
        try c.encode(pairs, forKey: .pairs)
        try c.encode(gameVersion, forKey: .gameVersion)
        try c.encode(created, forKey: .created)
    }

    public var farthest: Float { Float(bitPattern: farthestBits) }
    public var nearest: Float { Float(bitPattern: nearestBits) }

    /// Reads a saved calibration; nil when missing, unreadable or from another format version.
    public static func load(from file: URL) -> CameraCalibration? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536,
              let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(CameraCalibration.self, from: data),
              value.version == currentVersion, value.isPlausible else { return nil }
        return value
    }

    /// Limits a camera could have: finite, positive, the farthest beyond the nearest, offsets small.
    public var isPlausible: Bool {
        farthest.isFinite && nearest.isFinite && nearest >= 1e-6 && farthest > nearest * 1.05
            && !offsets.isEmpty && offsets.allSatisfy { $0 != 0 && abs($0) <= 256 && $0 % 4 == 0 } && pairs > 0
    }
}

/// The camera module's report for the app: what Camera reach is doing in the running game.
public struct CameraReachReport: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Switched off in the game's settings.
        case off
        /// On, but this game has never been calibrated.
        case notCalibrated
        /// The player is going through the calibration steps.
        case calibrating
        /// Looking for the calibrated limits in memory (after a launch or a scene change).
        case searching
        /// The limit is raised.
        case applied
        /// The calibrated limits were not found in memory (the game may have changed them).
        case notFound
        /// Calibration found that this game's limit cannot be raised.
        case unsupported
    }

    public var processIdentifier: Int32
    public var updated: Date = .now
    public var state: State = .off
    public var message: String = ""
    /// The game's own farthest zoom distance and the raised one, when known.
    public var gameLimit: Double = 0
    public var raisedLimit: Double = 0

    public init(processIdentifier: Int32) { self.processIdentifier = processIdentifier }

    public static let fileName = "camera-reach.json"
}
