// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppIntents
import Foundation
import MulgContracts

// Shortcuts and Siri actions (PLAN.md §13.3). They call the same `GameActions` as the
// `mulg` command. A game is picked from the installed games by name; its ID is the bundle ID
// `mulg profile list` prints.
// ponytail: titles are literals so Xcode can extract them; they are translated through the
// app's own string catalog.

public enum ProfileOption: String, AppEnum {
    case fps120, balanced, batterySaver

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Profile" }
    public static var caseDisplayRepresentations: [ProfileOption: DisplayRepresentation] {
        [.fps120: "120 FPS", .balanced: "Balanced", .batterySaver: "Battery saver"]
    }

    var profile: PerformanceProfile {
        switch self {
        case .fps120: .fps120
        case .balanced: .balanced
        case .batterySaver: .batterySaver
        }
    }

    /// The profile for `game`. The 120 FPS profile turns on the device identity, whose
    /// account-risk warning is shown in the app, never skipped (§15 rule 7).
    func profile(for game: String) throws -> PerformanceProfile {
        if self == .fps120 && !OnlineWarning.wasShown(.deviceIdentity, bundleIdentifier: game) {
            throw GameActions.Failure.settings("Apply the 120 FPS profile once in the app first, so its warning is shown.")
        }
        return profile
    }
}

/// An installed game as Shortcuts and Siri name it: the app's display name, with the bundle ID
/// as its identifier.
public struct GameEntity: AppEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Game" }
    public static var defaultQuery: GameQuery { GameQuery() }

    public let id: String
    public let name: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(id)")
    }

    init(bundleIdentifier: String, actions: GameActions) {
        let info = Bundle(url: actions.app(bundleIdentifier))?.infoDictionary
        id = bundleIdentifier
        name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? bundleIdentifier
    }
}

/// The installed games, found by bundle ID or by typing or saying part of the name.
public struct GameQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [GameEntity] {
        let actions = GameActions()
        let installed = Set(actions.installedGames())
        return identifiers.filter(installed.contains).map { GameEntity(bundleIdentifier: $0, actions: actions) }
    }

    public func entities(matching string: String) async throws -> [GameEntity] {
        try await suggestedEntities().filter {
            $0.name.localizedCaseInsensitiveContains(string) || $0.id.localizedCaseInsensitiveContains(string)
        }
    }

    public func suggestedEntities() async throws -> [GameEntity] {
        let actions = GameActions()
        return actions.installedGames().map { GameEntity(bundleIdentifier: $0, actions: actions) }
    }
}

/// Siri phrases. A phrase holds at most one parameter; Siri asks for the rest.
// ponytail: Siri reads App Shortcuts from the app bundle, so the Mulg app target must
// include `MulgIntentsPackage` in its own AppIntentsPackage and call
// `MulgShortcuts.updateAppShortcutParameters()` after installing or removing a game. That
// wiring lives in the app, which is upstream code (not done).
public struct MulgShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LaunchGameIntent(),
            phrases: ["Launch \(\.$game) in \(.applicationName)", "Play \(\.$game) with \(.applicationName)"],
            shortTitle: "Launch Game",
            systemImageName: "gamecontroller")
        AppShortcut(
            intent: SwitchProfileIntent(),
            phrases: ["Use the \(\.$profile) profile in \(.applicationName)",
                      "Switch to \(\.$profile) in \(.applicationName)"],
            shortTitle: "Switch Profile",
            systemImageName: "gauge.with.dots.needle.67percent")
    }
}

/// Lets the app's AppIntentsPackage include the intents, entity and shortcuts above.
public struct MulgIntentsPackage: AppIntentsPackage {}

public struct LaunchGameIntent: AppIntent {
    public static let title: LocalizedStringResource = "Launch Game"

    @Parameter(title: "Game") public var game: GameEntity
    @Parameter(title: "Profile") public var profile: ProfileOption?

    public init() {}

    public func perform() async throws -> some IntentResult {
        try GameActions().launch(game.id, profile: profile?.profile(for: game.id))
        return .result()
    }
}

public struct SwitchProfileIntent: AppIntent {
    public static let title: LocalizedStringResource = "Switch Profile"

    @Parameter(title: "Game") public var game: GameEntity
    @Parameter(title: "Profile") public var profile: ProfileOption

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let changes = try GameActions().applyProfile(profile.profile(for: game.id), to: game.id)
        return .result(value: changes.count)
    }
}

public struct ToggleMetalFXIntent: AppIntent {
    public static let title: LocalizedStringResource = "Toggle MetalFX"

    @Parameter(title: "Game") public var game: GameEntity
    @Parameter(title: "On") public var enabled: Bool

    public init() {}

    public func perform() async throws -> some IntentResult {
        // The account-risk warning is shown in the app, never skipped (§15 rule 7).
        if enabled && !OnlineWarning.wasShown(.metalFX, bundleIdentifier: game.id) {
            throw GameActions.Failure.settings("Turn on MetalFX once in the app first, so its warning is shown.")
        }
        try GameActions().edit(game.id) { $0.mulg.graphics.metalFX.enabled = enabled }
        return .result()
    }
}
#endif
