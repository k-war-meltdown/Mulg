// Host-side tool: macOS only, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MulgContracts
import MulgGUI

// mulg: the Shortcuts actions from the command line (PLAN.md §13.5).
//
//   mulg list                                  installed games
//   mulg launch <game> [--profile 120|balanced|battery]
//   mulg profile list                          the profiles
//   mulg profile set <game> <profile>          switch a game's profile
//   mulg modules <game>                        game-side modules and their state
//   mulg modules <game> enable|disable <module>
//
// <game> is the bundle ID, as `mulg list` prints it.

let usage = """
    usage: mulg list
           mulg launch <game> [--profile 120|balanced|battery]
           mulg profile list
           mulg profile set <game> <profile>
           mulg modules <game> [enable|disable <module>]
    """

func profile(_ name: String) throws -> PerformanceProfile {
    guard let profile = PerformanceProfile(argument: name) else { throw GameActions.Failure.unknownProfile(name) }
    return profile
}

func run(_ arguments: [String], actions: GameActions = GameActions()) throws -> Bool {
    switch arguments {
    case ["list"]:
        actions.installedGames().forEach { print($0) }
    case let args where args.first == "launch" && (args.count == 2 || (args.count == 4 && args[2] == "--profile")):
        try actions.launch(args[1], profile: args.count == 4 ? profile(args[3]) : nil)
    case ["profile", "list"]:
        let names: [PerformanceProfile: String] = [.fps120: "120", .balanced: "balanced", .batterySaver: "battery"]
        PerformanceProfile.allCases.forEach { print("\(names[$0] ?? $0.rawValue)\t\($0.title)") }
    case let args where args.count == 4 && args[0] == "profile" && args[1] == "set":
        let changes = try actions.applyProfile(profile(args[3]), to: args[2])
        changes.forEach { print("\($0.title): \($0.old) -> \($0.new)") }
        if changes.isEmpty { print("Already on this profile.") }
    case let args where args.count == 2 && args[0] == "modules":
        let settings = SettingsStore(paths: actions.paths).load(bundleIdentifier: args[1])
        if let problem = settings.problem { throw GameActions.Failure.settings(problem.description) }
        for row in ModuleRow.rows(for: settings.settings) {
            print("\(row.module.rawValue)\t\(row.enabled ? "on" : "off")\(row.locked ? " (always on)" : "")")
        }
    case let args where args.count == 4 && args[0] == "modules" && ["enable", "disable"].contains(args[2]):
        guard let module = ModuleID(rawValue: args[3]) else { throw GameActions.Failure.unknownModule(args[3]) }
        try actions.setModule(module, enabled: args[2] == "enable", for: args[1])
    default:
        return false
    }
    return true
}

do {
    if try !run(Array(CommandLine.arguments.dropFirst())) {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(64)
    }
} catch {
    FileHandle.standardError.write(Data("mulg: \(error)\n".utf8))
    exit(1)
}
#endif
