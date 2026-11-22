import Foundation

/// Versions that the app and the runtime injected into each game must agree on
/// (PLAN.md §1.5 rule 11).
public enum MulgVersion {
    /// Human-readable version of this build.
    public static let current = "0.1.0"

    /// Bumped whenever the app and the runtime must be updated together, for example
    /// when the meaning of a setting changes. Games injected with a different value are
    /// asked to be re-injected.
    // Protocol 7 adds explicit file adapter exports alongside the storage adapters.
    // A protocol-6 runtime cannot satisfy those imports; require a paired app/runtime update.
    // Existing schema-4 credentials, encryption keys and persistent references are retained.
    public static let runtimeProtocol = 7

    public enum Compatibility: Sendable, Equatable {
        case compatible
        /// The game was injected by an app whose runtime protocol differs (or is unknown).
        case reinjectNeeded(injectedVersion: String?)
    }

    public static func compatibility(of engine: EngineSettings) -> Compatibility {
        guard let injected = engine.injectedRuntimeProtocol else {
            // Games injected by upstream Mulg carry no protocol number. They still
            // work, because the settings format is backwards compatible, but the user is
            // told to re-inject to get this fork's runtime.
            return .reinjectNeeded(injectedVersion: engine.injectedRuntimeVersion)
        }
        return injected == runtimeProtocol ? .compatible : .reinjectNeeded(injectedVersion: engine.injectedRuntimeVersion)
    }
}
