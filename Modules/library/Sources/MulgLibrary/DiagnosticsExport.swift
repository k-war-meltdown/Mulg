// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MulgContracts

/// This Mac, as bug reports and shared results describe it.
public struct MacInfo: Sendable, Equatable {
    public let model: String
    public let systemVersion: String

    public init(model: String, systemVersion: String) {
        self.model = model
        self.systemVersion = systemVersion
    }

    public static func current() -> MacInfo {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        let model = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return MacInfo(model: model, systemVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    }
}

/// The "Export diagnostics" zip on each game's settings page (PLAN.md §8.3). It is saved
/// where the user chooses and sent nowhere.
public enum DiagnosticsExport {
    /// The game's settings without account data. Keychain databases (MulgChain) are never
    /// read, so they cannot end up in the zip. Custom environment variables keep their names (they
    /// matter for a bug report) but lose their values: that is where API keys, tokens and server
    /// addresses get pasted, and the zip is meant to be attached to public reports.
    public static func sanitized(_ settings: GameSettings) -> GameSettings {
        var copy = settings
        copy.discordActivity = DiscordActivitySettings()
        copy.mulg.engine.environment = copy.mulg.engine.environment.mapValues { _ in "<removed>" }
        return copy
    }

    /// Module list, versions and this Mac, as plain text.
    public static func summary(_ settings: GameSettings, mac: MacInfo) -> String {
        var lines = [
            "Mulg \(MulgVersion.current), runtime protocol \(MulgVersion.runtimeProtocol)",
            "Injected runtime: \(settings.mulg.engine.injectedRuntimeVersion ?? "none")"
                + " (protocol \(settings.mulg.engine.injectedRuntimeProtocol.map(String.init) ?? "none"))",
            "Mac: \(mac.model), macOS \(mac.systemVersion)",
            "Game: \(settings.bundleIdentifier)",
            "",
            "Modules:"
        ]
        for module in ModuleID.allCases.filter(\.runsInGame).sorted() {
            lines.append("  \(module.rawValue): \(settings.mulg.engine.isModuleEnabled(module) ? "on" : "off")")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the zip. `logs` is swappable so tests do not read the system log.
    public static func export(
        _ settings: GameSettings,
        to archive: URL,
        paths: ContainerPaths = .current(),
        mac: MacInfo = .current(),
        logs: () -> String = DiagnosticsExport.recentLogs,
        progress: (OperationProgress) -> Void = { _ in }
    ) throws {
        let files = FileManager.default
        let staging = files.temporaryDirectory.appendingPathComponent("mulg-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let folder = staging.appendingPathComponent("\(settings.bundleIdentifier) diagnostics", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }

        try SettingsStore.encode(sanitized(settings)).write(to: folder.appendingPathComponent("Settings.plist"))
        try Data(summary(settings, mac: mac).utf8).write(to: folder.appendingPathComponent("Summary.txt"))
        let marker = paths.safeModeMarker(for: settings.bundleIdentifier)
        for (source, name) in [(marker, "Launch.json"), (marker.appendingPathExtension("last.json"), "PreviousLaunch.json")] {
            if files.fileExists(atPath: source.path) {
                try files.copyItem(at: source, to: folder.appendingPathComponent(name))
            }
        }
        try OperationProgress.begin(.logs, 0, of: 3, progress)
        try Data(logs().utf8).write(to: folder.appendingPathComponent("Logs.txt"))
        // Latency samples and HUD logs the runtime wrote for this game.
        try OperationProgress.begin(.measurements, 1, of: 3, progress)
        let measured = paths.diagnosticsDirectory(for: settings.bundleIdentifier)
        if files.fileExists(atPath: measured.path) {
            try files.copyItem(at: measured, to: folder.appendingPathComponent("Measurements", isDirectory: true))
        }
        try OperationProgress.begin(.archive, 2, of: 3, canCancel: false, progress)
        try? files.removeItem(at: archive)
        do {
            try Command.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, archive.path])
        } catch {
            try? files.removeItem(at: archive)  // never leave half a zip that looks like an export
            throw error
        }
    }

    /// The last hour of log messages from Mulg and its games.
    public static func recentLogs() -> String {
        (try? Command.run("/usr/bin/log", [
            "show", "--last", "1h", "--style", "compact",
            "--predicate", "subsystem == \"\(MulgLog.subsystem)\" OR process == \"Mulg\""
        ])) ?? "Could not read the system log."
    }
}
#endif
