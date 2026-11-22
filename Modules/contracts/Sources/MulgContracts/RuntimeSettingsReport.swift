import Foundation

/// Configuration acknowledged by the current runtime, separate from the host's saved file.
/// Launch values remain available so the UI can identify settings requiring a restart.
public struct RuntimeSettingsReport: Codable, Sendable {
    public let processIdentifier: Int32
    /// The same immutable marker as startup and compatibility evidence for this runtime.
    public let launchSessionID: UUID?
    public let updated: Date
    public let launch: GameSettings
    public let acknowledged: GameSettings

    public init(processIdentifier: Int32, launch: GameSettings, acknowledged: GameSettings,
                launchSessionID: UUID? = nil) {
        self.processIdentifier = processIdentifier
        self.launchSessionID = launchSessionID
        self.updated = .now
        self.launch = launch
        self.acknowledged = acknowledged
    }
}
