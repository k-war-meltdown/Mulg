import Foundation

/// Device output policy, independent of a game's source/mixer PCM format.
public struct AudioOutputSettings: Codable, Sendable, Equatable {
    /// Every game runs at the iPad's native output rate, which is not a setting. iOS audio engines
    /// are only ever run at 48 kHz on an iPad; Genshin's Wwise resampler spun forever on a 192 kHz
    /// DAC and froze the game once its world loaded. The device is switched for the game's
    /// lifetime and restored on exit. Older settings files may still contain a `rate`; it is ignored.
    public static let iPadSampleRate: Double = 48_000
    public enum Depth: String, Codable, Sendable, CaseIterable {
        case preserveDevice, bits24, bits32
        public var bits: Int {
            switch self { case .preserveDevice: 0; case .bits24: 24; case .bits32: 32 }
        }
        public var title: String {
            switch self { case .preserveDevice: "Keep device format"; case .bits24: "24-bit PCM"; case .bits32: "32-bit PCM" }
        }
    }
    public var depth: Depth = .preserveDevice
    public var restoreOnExit = true
    public init() {}
    enum CodingKeys: String, CodingKey { case depth, restoreOnExit }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        depth = try c.enumValue(.depth, default: .preserveDevice)
        restoreOnExit = try c.decodeIfPresent(Bool.self, forKey: .restoreOnExit) ?? true
    }
}

/// Verified hardware format. A session/mixer may run at a different rate and be resampled.
public struct AudioOutputReport: Codable, Sendable {
    public var processIdentifier: Int32
    public var updated: Date = .now
    public var deviceName: String = "No output device"
    public var requestedSampleRate: Double = 0
    public var preferredSessionRate: Double = 0
    public var sampleRate: Double = 0
    public var bitDepth: Int = 0
    public var floatingPoint: Bool = false
    public var availableSampleRates: [Double] = []
    public var availableBitDepths: [Int] = []
    public var sessionSampleRate: Double = 0
    public var state: String = "waiting"
    public var message: String = "Waiting for the audio device."
    public init(processIdentifier: Int32) { self.processIdentifier = processIdentifier }
}
