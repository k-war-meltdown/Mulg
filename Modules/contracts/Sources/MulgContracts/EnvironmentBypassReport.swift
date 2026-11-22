import Foundation

/// Runtime evidence of a compatibility configuration, not proof that a game's protection passed.
public struct EnvironmentBypassReport: Codable, Sendable, Equatable {
    public var processIdentifier: Int32
    /// Shared runtime-session marker. Optional for reports written by older runtimes.
    public var launchSessionID: UUID?
    public var launchStartedAt: Date
    public var bundleIdentifier: String
    public var deviceIdentifier: String
    public var enabled: Bool
    public var deviceRecognized: Bool
    public var knownSDKChecksRequested: Bool
    public var installedSDKChecks: Int32
    public var availableSDKChecks: Int32
    /// Optional so reports from older runtimes remain readable.
    public var mobileUIHooksInstalled: Int32?
    public var identityAudit: DeviceIdentityAudit?

    public init(processIdentifier: Int32, launchStartedAt: Date, bundleIdentifier: String, deviceIdentifier: String,
                enabled: Bool, deviceRecognized: Bool, knownSDKChecksRequested: Bool,
                installedSDKChecks: Int32, availableSDKChecks: Int32, mobileUIHooksInstalled: Int32? = nil,
                identityAudit: DeviceIdentityAudit? = nil, launchSessionID: UUID? = nil) {
        self.processIdentifier = processIdentifier
        self.launchSessionID = launchSessionID
        self.launchStartedAt = launchStartedAt
        self.bundleIdentifier = bundleIdentifier
        self.deviceIdentifier = deviceIdentifier
        self.enabled = enabled
        self.deviceRecognized = deviceRecognized
        self.knownSDKChecksRequested = knownSDKChecksRequested
        self.installedSDKChecks = installedSDKChecks
        self.availableSDKChecks = availableSDKChecks
        self.mobileUIHooksInstalled = mobileUIHooksInstalled
        self.identityAudit = identityAudit
    }

    /// PID and bundle ID alone can match an old report after macOS reuses a PID.
    /// Require the runtime snapshot to have started during this actual process lifetime.
    /// A missing native launch date cannot establish a current session.
    public func belongsToLaunch(bundleIdentifier: String, processIdentifier: Int32,
                                processLaunchDate: Date?) -> Bool {
        guard self.bundleIdentifier == bundleIdentifier,
              self.processIdentifier == processIdentifier,
              let processLaunchDate else { return false }
        return launchStartedAt >= processLaunchDate
    }
}
