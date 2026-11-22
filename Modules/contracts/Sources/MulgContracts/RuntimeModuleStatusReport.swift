import Foundation

/// The module-status portion of startup.json. Unknown hook/timing fields are ignored.
/// A shared session marker prevents independently written reports from different launches
/// being combined, including after PID reuse. This is diagnostic metadata, not attestation.
public struct RuntimeModuleStatusReport: Codable, Sendable, Equatable {
    public struct Module: Codable, Sendable, Equatable {
        public let id: String
        public let state: String
        public init(id: String, state: String) { self.id = id; self.state = state }
    }

    public let processIdentifier: Int32
    public let launchSessionID: UUID?
    public let safeMode: Bool
    public let modules: [Module]

    public init(processIdentifier: Int32, launchSessionID: UUID? = nil, safeMode: Bool, modules: [Module]) {
        self.processIdentifier = processIdentifier
        self.launchSessionID = launchSessionID
        self.safeMode = safeMode
        self.modules = modules
    }

    public var identityState: String? { modules.first { $0.id == "identity" }?.state }
    public var identityDisabledByRecovery: Bool { identityState == "offInSafeMode" }

    /// Preparation has completed in these engine states. Degraded modules still run
    /// their available hooks and late-image retries; their coverage remains partial.
    /// A disabled, failed, core-only or unknown state does not establish identity setup.
    public var identityPrepared: Bool {
        guard let state = identityState else { return false }
        return state == "prepared" || state == "active" || state.hasPrefix("degraded(")
    }

    /// Legacy reports can match by PID only if both lack the new marker. Never mix a new
    /// marked report with an unmarked one. Live legacy evidence also needs a native launch date.
    public func matches(processIdentifier: Int32, launchSessionID: UUID?) -> Bool {
        self.processIdentifier == processIdentifier && self.launchSessionID == launchSessionID
    }
}
