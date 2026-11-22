import Foundation
import MulgBridge
import MulgContracts
import os

/// Everything a game-side module gets from the engine. Modules receive what they need here
/// instead of reaching for global singletons (PLAN.md §12 #10).
@MainActor
public final class ModuleContext {
    public let bundleIdentifier: String
    /// Stable for every report in this runtime; never regenerated on a settings reload.
    public let launchSessionID = UUID()
    public let paths: ContainerPaths
    public let settingsStore: SettingsStore
    /// The game's settings: loaded at start-up, then kept in step with the file (`reloadSettings`).
    public private(set) var settings: GameSettings
    private let launchSettings: GameSettings
    public let launch: SafeMode.Launch
    public let events: EventBus
    public let hooks: HookRegistry
    public let hotkeys: HotkeyCenter
    /// Commands in the in-game menu bar.
    public let menus: MenuCenter
    public let notices: NoticeCenter
    /// The macOS bridge, or nil when its bundle could not be loaded.
    public let bridge: (any MacBridge)?
    public var reportLaunchStage: (@MainActor (SafeMode.Stage, ModuleID?) -> Void)?
    /// The control editor the mapper module supplies. Controls opens it for ⌘K and falls back to
    /// its own editor while this is nil (mapper switched off).
    public var controlEditor: (any ControlEditing)?

    public init(
        bundleIdentifier: String,
        paths: ContainerPaths,
        settingsStore: SettingsStore,
        settings: GameSettings,
        launch: SafeMode.Launch,
        bridge: (any MacBridge)?,
        events: EventBus = EventBus(),
        hooks: HookRegistry = HookRegistry(),
        hotkeys: HotkeyCenter = HotkeyCenter(),
        menus: MenuCenter = MenuCenter(),
        notices: NoticeCenter = NoticeCenter()
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.paths = paths
        self.settingsStore = settingsStore
        self.settings = settings
        self.launchSettings = settings
        self.launch = launch
        self.bridge = bridge
        self.events = events
        self.hooks = hooks
        self.hotkeys = hotkeys
        self.menus = menus
        self.notices = notices
    }

    public func logger(for module: ModuleID) -> Logger {
        MulgLog.logger(module)
    }

    /// Changes settings from inside the game (for example the MetalFX hotkey) and saves them,
    /// so the Mulg app shows the same state.
    @discardableResult
    public func updateSettings(_ change: (inout GameSettings) -> Void) -> Bool {
        let old = settings
        var candidate = old
        change(&candidate)
        guard candidate != old else { return true }
        do {
            settings = try settingsStore.save(candidate, basedOn: old)
        } catch {
            logger(for: .engine).error("\(error.description, privacy: .public)")
            notices.show(Notice("Settings not saved", lines: ["The change could not be written. Try again."], style: .warning))
            return false
        }
        events.publish(SettingsChanged(old: old, new: settings))
        writeSettingsReport()
        return true
    }

    /// Reads the settings file again and sends `SettingsChanged` when it differs from what the
    /// game runs with. A missing or unreadable file is ignored (a reset, or the app halfway through
    /// a write), so the game never drops to defaults mid-play.
    @discardableResult
    public func reloadSettings() -> Bool {
        guard FileManager.default.fileExists(atPath: paths.settingsFile(for: bundleIdentifier).path) else { return false }
        let loaded = settingsStore.load(bundleIdentifier: bundleIdentifier)
        guard loaded.problem == nil, loaded.settings != settings else { return false }
        let old = settings
        settings = loaded.settings
        events.publish(SettingsChanged(old: old, new: loaded.settings))
        writeSettingsReport()
        return true
    }

    public func writeSettingsReport() {
        let report = RuntimeSettingsReport(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                                          launch: launchSettings, acknowledged: settings, launchSessionID: launchSessionID)
        ReportWriter.shared.writeCompactSnapshot(report, to: paths.diagnosticsDirectory(for: bundleIdentifier)
            .appendingPathComponent("settings-runtime.json"))
    }
}
