import Foundation
import MulgContracts
import MulgIdentityHooks

/// What the identity hooks report for one game.
public struct IdentityConfiguration: Sendable, Equatable {
    public let machine: String
    public let boardID: String

    public init(machine: String, boardID: String) {
        self.machine = machine
        self.boardID = boardID
    }

    /// The identity for a game's settings, or nil when the identifier is not in the catalog.
    /// An unknown identifier is never reported with a made-up board ID (PLAN.md §3.7).
    public init?(settings: GameSettings) {
        guard let profile = DeviceCatalog.profile(for: settings.iosDeviceModel) else {
            return nil
        }
        self.init(machine: profile.id, boardID: profile.boardID)
    }
}

/// Entry point of the identity module inside the game (PLAN.md §1.5 rule 5: it starts right
/// after settings, before the game can read device information).
public enum IdentityModule {
    public static let moduleID = "identity"

    public enum StartResult: Sendable, Equatable {
        case active(IdentityConfiguration)
        case switchedOff
        case unknownDevice(String)
    }

    /// Configures the hooks from a game's settings. When the module is switched off for the
    /// game, or the device is unknown, the hooks pass everything through to the real calls.
    @discardableResult
    public static func start(settings: GameSettings) -> StartResult {
        mulg_identity_set_game_only_answers(settings.mulg.identity.environmentBypass)
        guard settings.mulg.engine.isModuleEnabled(moduleID) else {
            mulg_identity_configure(nil, nil)
            return .switchedOff
        }
        guard let configuration = IdentityConfiguration(settings: settings) else {
            mulg_identity_configure(nil, nil)
            return .unknownDevice(settings.iosDeviceModel)
        }
        configuration.machine.withCString { machine in
            configuration.boardID.withCString { board in
                mulg_identity_configure(machine, board)
            }
        }
        return .active(configuration)
    }

    public static var isActive: Bool {
        mulg_identity_is_active() != 0
    }
}
