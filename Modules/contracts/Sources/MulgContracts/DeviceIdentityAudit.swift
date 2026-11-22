import Foundation

/// Installed/configured signals, not a claim of game acceptance or Apple attestation.
public struct IdentityHookCoverage: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var installed: Int32
    public var expected: Int32

    public init(id: String, title: String, installed: Int32, expected: Int32) {
        self.id = id; self.title = title
        self.installed = installed; self.expected = expected
    }

    public var complete: Bool { installed >= expected }
}

/// Compares the published identity table with the selected profile. A match establishes
/// configured consistency, not that a game's SDK queried or accepted these answers.
public struct DeviceIdentitySignal: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var expected: String
    public var configured: String?

    public init(id: String, title: String, expected: String, configured: String?) {
        self.id = id
        self.title = title
        self.expected = expected
        self.configured = configured
    }

    public var matches: Bool { configured == expected }
}

public struct DeviceIdentityAudit: Codable, Sendable, Equatable {
    public var profileName: String
    public var boardIdentifier: String
    public var hardwarePlatform: String
    public var cpuCores: UInt32?
    public var memoryLimitBytes: UInt64
    public var reportedMemoryBytes: UInt64
    public var configured: Bool
    public var gameOnlyAnswers: Bool
    public var boardVerified: Bool
    public var hooks: [IdentityHookCoverage]
    public var warnings: [String]
    /// Optional to keep reports written before table comparisons readable.
    public var signals: [DeviceIdentitySignal]?
    /// Optional so pre-variant runtime reports retain their original meaning.
    public var deviceConfiguration: MobileDeviceConfiguration?

    public init(profileName: String, boardIdentifier: String, hardwarePlatform: String, cpuCores: UInt32?,
                memoryLimitBytes: UInt64, reportedMemoryBytes: UInt64, configured: Bool, gameOnlyAnswers: Bool,
                boardVerified: Bool, hooks: [IdentityHookCoverage], warnings: [String], signals: [DeviceIdentitySignal]? = nil,
                deviceConfiguration: MobileDeviceConfiguration? = nil) {
        self.profileName = profileName; self.boardIdentifier = boardIdentifier
        self.hardwarePlatform = hardwarePlatform; self.cpuCores = cpuCores
        self.memoryLimitBytes = memoryLimitBytes; self.reportedMemoryBytes = reportedMemoryBytes
        self.configured = configured; self.gameOnlyAnswers = gameOnlyAnswers
        self.boardVerified = boardVerified; self.hooks = hooks; self.warnings = warnings
        self.signals = signals
        self.deviceConfiguration = deviceConfiguration
    }

    public var hasMissingHooks: Bool { hooks.contains { !$0.complete } }
    public var hasMismatchedSignals: Bool { signals?.contains { !$0.matches } ?? false }
}
