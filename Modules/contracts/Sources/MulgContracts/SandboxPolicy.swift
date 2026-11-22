import Foundation

/// The settings that widen a game's sandbox when the app signs it: the compatibility bypass and Discord
/// activity. A game may write its own settings file, so the app never takes these from it when it builds
/// the sandbox (a game could otherwise switch on a looser sandbox for itself). They are recorded here, in
/// a folder no game's sandbox grants, and only when the player changes them in Mulg (2026-10-10).
public struct SandboxPolicy: Codable, Sendable, Equatable {
    public var bypass: Bool
    public var discordActivity: Bool

    /// The defaults of a new game's settings.
    public init(bypass: Bool = GameSettings().bypass, discordActivity: Bool = GameSettings().discordActivity.enable) {
        self.bypass = bypass
        self.discordActivity = discordActivity
    }

    public init(_ settings: GameSettings) {
        self.init(bypass: settings.bypass, discordActivity: settings.discordActivity.enable)
    }

    /// The same two values from a settings file's property-list tree (the app's legacy schema); missing keys
    /// take the defaults.
    public init(tree: [String: Any]) {
        let defaults = SandboxPolicy()
        self.init(bypass: tree["bypass"] as? Bool ?? defaults.bypass,
                  discordActivity: (tree["discordActivity"] as? [String: Any])?["enable"] as? Bool ?? defaults.discordActivity)
    }

    static func folder(_ paths: ContainerPaths) -> URL {
        paths.mulgStateDirectory.appendingPathComponent("SandboxPolicy", isDirectory: true)
    }

    static func file(for bundleIdentifier: String, paths: ContainerPaths) -> URL {
        folder(paths).appendingPathComponent(bundleIdentifier + ".plist", isDirectory: false)
    }

    /// Written once the settings files of an older Mulg were adopted.
    static func migrationMarker(_ paths: ContainerPaths) -> URL {
        folder(paths).appendingPathComponent(".migrated", isDirectory: false)
    }

    /// What the player chose for this game. Defaults when nothing was recorded.
    public static func load(for bundleIdentifier: String, paths: ContainerPaths = .current()) -> SandboxPolicy {
        migrateIfNeeded(paths: paths)
        guard let data = try? Data(contentsOf: file(for: bundleIdentifier, paths: paths)),
              let policy = try? PropertyListDecoder().decode(SandboxPolicy.self, from: data) else { return SandboxPolicy() }
        return policy
    }

    public static func save(_ policy: SandboxPolicy, for bundleIdentifier: String, paths: ContainerPaths = .current()) throws {
        guard GameSessionLease.isValidBundleIdentifier(bundleIdentifier) else { throw GameSessionLease.Failure.invalidIdentifier }
        let target = file(for: bundleIdentifier, paths: paths)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(policy).write(to: target, options: .atomic)
    }

    /// Records the values the player changed: `edited` against `base`, what the screen showed. A value the
    /// screen did not change keeps what was recorded, whatever the settings file says now. Without a base
    /// (a reset, or a settings file the app had to write anew) `edited` is recorded whole.
    public static func record(base: SandboxPolicy?, edited: SandboxPolicy, for bundleIdentifier: String,
                              paths: ContainerPaths = .current()) throws {
        let current = load(for: bundleIdentifier, paths: paths)
        var next = current
        if base == nil || base?.bypass != edited.bypass { next.bypass = edited.bypass }
        if base == nil || base?.discordActivity != edited.discordActivity { next.discordActivity = edited.discordActivity }
        if next != current || !FileManager.default.fileExists(atPath: file(for: bundleIdentifier, paths: paths).path) {
            try save(next, for: bundleIdentifier, paths: paths)
        }
    }

    /// Once per Mac: the values the settings files hold when this version first runs are adopted, so an
    /// update changes no game's sandbox. Later changes a game makes to its file are never adopted.
    static func migrateIfNeeded(paths: ContainerPaths) {
        let marker = migrationMarker(paths)
        let files = FileManager.default
        guard !files.fileExists(atPath: marker.path) else { return }
        try? files.createDirectory(at: folder(paths), withIntermediateDirectories: true)
        let settings = (try? files.contentsOfDirectory(at: paths.appSettingsDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in settings where url.pathExtension == "plist" {
            let identifier = url.deletingPathExtension().lastPathComponent
            guard GameSessionLease.isValidBundleIdentifier(identifier),
                  !files.fileExists(atPath: file(for: identifier, paths: paths).path),
                  let data = try? Data(contentsOf: url),
                  let tree = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            try? save(SandboxPolicy(tree: tree), for: identifier, paths: paths)
        }
        files.createFile(atPath: marker.path, contents: nil)
    }
}
