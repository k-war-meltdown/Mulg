import Foundation

/// Every module of the app (PLAN.md §1.3). Used for settings, logging, hook ownership
/// and the per-game Modules page.
public enum ModuleID: String, Sendable, Codable, CaseIterable, Comparable {
    // Host process
    case gui, library, store, updater
    // Both processes
    case contracts, keymaps, diagnostics, integrations
    case controlLayout = "control-layout"
    // Game process
    case engine, identity, display, graphics, controls, mapper, camera, bridge

    /// Whether the module runs inside the game (and can be switched off per game).
    public var runsInGame: Bool {
        switch self {
        case .engine, .identity, .display, .graphics, .controls, .mapper, .camera, .bridge, .diagnostics, .integrations:
            true
        case .gui, .library, .store, .updater, .contracts, .keymaps, .controlLayout:
            false
        }
    }

    /// Modules that can never be switched off, because everything else depends on them.
    public var isEssential: Bool {
        switch self {
        case .contracts, .keymaps, .controlLayout, .engine, .bridge: true
        default: false
        }
    }

    public static func < (lhs: ModuleID, rhs: ModuleID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
