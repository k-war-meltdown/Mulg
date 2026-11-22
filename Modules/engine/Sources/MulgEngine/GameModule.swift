import Foundation
import MulgContracts

/// A module that runs inside the game (PLAN.md §1).
///
/// Start-up happens in two phases (PLAN.md §16.2 E5):
/// - `prepare` runs before the game's own code. Only work that must be ready before the
///   game reads anything belongs here: identity, screen hooks.
/// - `activate` runs once the game's first scene is active. Everything else (Discord,
///   overlays, observers) goes here so the game starts sooner.
@MainActor
public protocol GameModule: AnyObject {
    var id: ModuleID { get }
    /// Experimental modules are switched off automatically in safe mode (§1.5 rule 10).
    var isExperimental: Bool { get }
    var prerequisites: [ModuleID] { get }
    func requiresBridge(_ settings: GameSettings) -> Bool
    func prepare(_ context: ModuleContext) throws
    /// Stable services that must survive disabling an experimental feature module.
    func prepareCore(_ context: ModuleContext) throws -> Bool
    func activate(_ context: ModuleContext)
    /// Retry unresolved class hooks after dyld publishes another image. No setup is repeated.
    func imagesChanged(_ context: ModuleContext)
}

public extension GameModule {
    var isExperimental: Bool { false }
    var prerequisites: [ModuleID] { id == .engine ? [] : [.engine] }
    func requiresBridge(_ settings: GameSettings) -> Bool { false }
    func prepareCore(_ context: ModuleContext) throws -> Bool { false }
    func activate(_ context: ModuleContext) {}
    func imagesChanged(_ context: ModuleContext) {}
}

/// Why a module did not start, or that it did.
public enum ModuleState: Sendable, Equatable {
    case prepared
    case active
    case switchedOff
    case offInSafeMode
    case failed(String)
    case unavailable(String)
    case coreOnly(String)
    case degraded(String)

    public var isRunning: Bool {
        switch self {
        case .prepared, .active, .coreOnly, .degraded: true
        default: false
        }
    }
}

/// What happened to one module during start-up, for the Modules page and diagnostics.
public struct ModuleReport: Sendable, Equatable {
    public let id: ModuleID
    public var state: ModuleState
    public var prepareDuration: Duration
    public var activateDuration: Duration
}
