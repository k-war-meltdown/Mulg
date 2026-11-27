// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import Foundation
import MulgContracts
import MulgLibrary

/// The actions shared by Shortcuts (App Intents) and the `mulg` command (PLAN.md §13.3,
/// §13.5): launch a game with a profile, switch profile, and switch modules.
public struct GameActions: Sendable {
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case notInstalled(String)
        case unknownProfile(String)
        case unknownModule(String)
        case settings(String)

        public var description: String {
            switch self {
            case let .notInstalled(game): "\(game) is not installed in Mulg."
            case let .unknownProfile(name): "Unknown profile \"\(name)\". Use 120, balanced or battery."
            case let .unknownModule(name): "Unknown or essential module \"\(name)\"."
            case let .settings(reason): reason
            }
        }
    }

    public let paths: ContainerPaths

    public init(paths: ContainerPaths = .current()) {
        self.paths = paths
    }

    /// Mulg keeps each installed game as `<bundle ID>.app` in its Applications folder.
    public func app(_ bundleIdentifier: String) -> URL {
        paths.applicationsDirectory.appendingPathComponent("\(bundleIdentifier).app", isDirectory: true)
    }

    public func installedGames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.applicationsDirectory.path)) ?? []
        return names.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }.sorted()
    }

    /// Loads, changes and saves a game's settings. A settings file that cannot be read is
    /// never overwritten with defaults.
    public func edit<Result>(_ bundleIdentifier: String, _ change: (inout GameSettings) throws -> Result) throws -> Result {
        let store = SettingsStore(paths: paths)
        let loaded = store.load(bundleIdentifier: bundleIdentifier)
        if let problem = loaded.problem {
            throw Failure.settings(problem.description)
        }
        var settings = loaded.settings
        let result = try change(&settings)
        do {
            try store.save(settings, basedOn: loaded.settings)
        } catch {
            throw Failure.settings(error.description)
        }
        return result
    }

    /// Records what an install put into the game (PLAN.md §1.5 rule 6): the runtime version,
    /// so MulgRuntime does not ask for a re-inject, and the hash of every user plugin it may
    /// load. Call after the last signing pass; signing rewrites the plugins.
    public func recordInjection(of bundleIdentifier: String, app: URL) throws {
        try edit(bundleIdentifier) { settings in
            settings.mulg.engine.injectedRuntimeVersion = MulgVersion.current
            settings.mulg.engine.injectedRuntimeProtocol = MulgVersion.runtimeProtocol
            settings.mulg.engine.trustedPluginHashes = GameInstaller.pluginHashes(in: app)
        }
    }

    public func applyProfile(_ profile: PerformanceProfile, to bundleIdentifier: String) throws -> [SettingChange] {
        try edit(bundleIdentifier) { settings in
            PerformancePreset.apply(profile, to: &settings, batteryCap: settings.mulg.display.batteryFrameRateCap)
        }
    }

    /// A freshly installed game starts with no debugging at all: debug log, measurements, crash and
    /// freeze reports, Metal HUD and keychain debugging off. Each can be switched on per game later.
    public func disableDebugging(for bundleIdentifier: String) throws {
        try edit(bundleIdentifier) { settings in
            settings.mulg.diagnostics = .allOff
            settings.metalHUD = false
            settings.mulgChainDebugging = false
        }
    }

    /// Debugging runs only while the player switches it on in a game's settings (2026-10-11, user request):
    /// every start of Mulg switches the debug log and its categories, HUD logging, the Metal HUD and keychain
    /// debugging off again, for every game. Player options that are not debuggers (crash reports, the
    /// performance overlay, latency measurement) keep their setting. A game whose debugging is already off is
    /// not written. Returns whether anything was switched off.
    @discardableResult
    public func switchOffDebugging(for bundleIdentifier: String) throws -> Bool {
        let current = SettingsStore(paths: paths).load(bundleIdentifier: bundleIdentifier).settings
        guard Self.debugging(current) else { return false }
        try edit(bundleIdentifier) { settings in
            settings.mulg.diagnostics.debugger = false
            settings.mulg.diagnostics.debugCPU = false
            settings.mulg.diagnostics.debugGraphics = false
            settings.mulg.diagnostics.debugShaders = false
            settings.mulg.diagnostics.debugGameLog = false
            settings.mulg.diagnostics.hudLogging = false
            settings.metalHUD = false
            settings.mulgChainDebugging = false
        }
        return true
    }

    static func debugging(_ settings: GameSettings) -> Bool {
        let diagnostics = settings.mulg.diagnostics
        return diagnostics.debugger || diagnostics.debugCPU || diagnostics.debugGraphics || diagnostics.debugShaders
            || diagnostics.debugGameLog || diagnostics.hudLogging || settings.metalHUD || settings.mulgChainDebugging
    }

    /// A freshly installed game may use nothing: microphone, camera, photos and location are
    /// answered "denied", and HUD anchoring (which needs Screen Recording) starts off, so a new game
    /// never shows a permission dialog. Each can be allowed on the game's Privacy page.
    public func applyPrivacyDefaults(for bundleIdentifier: String) throws {
        try edit(bundleIdentifier) { settings in
            settings.mulg.privacy = PrivacySettings()
            settings.mulg.controls.automaticHUDAnchoring = false
        }
    }

    /// Install rule (2026-10-10, user request): every installed game keeps playing when another app or Space
    /// comes forward, instead of pausing itself. Applied on each install and update; the switches stay
    /// editable per game afterwards (Background, battery & sound).
    public func applyBackgroundPlayDefaults(for bundleIdentifier: String) throws {
        try edit(bundleIdentifier) { settings in
            settings.mulg.engine.keepRunningUnfocused = true
            settings.mulg.engine.keepForegroundOnOtherSpaces = true
            // ⌘Q quits at once, as in any Mac app (2026-11-27): it is the way out of a game that keeps the pointer.
            settings.mulg.engine.confirmQuitShortcut = false
            settings.mulg.engine.confinePointer = true
        }
    }

    /// New games use desktop pixels, a 120 FPS target and no automatic saving/downscaling modes.
    /// A profile explicitly selected later remains available through the normal profile controls.
    public func applyPerformanceDefaults(for bundleIdentifier: String) throws {
        try edit(bundleIdentifier) { settings in
            DesktopGameDefaults.apply(to: &settings)
        }
    }

    public func setModule(_ module: ModuleID, enabled: Bool, for bundleIdentifier: String) throws {
        guard module.runsInGame, !module.isEssential else { throw Failure.unknownModule(module.rawValue) }
        try edit(bundleIdentifier) { ModuleRow.set(module, enabled: enabled, in: &$0) }
    }

    /// Whether the game sees the Mac's real CPU counts (the default), allowing its engine to
    /// size worker pools for available cores. This does not guarantee use of every core.
    /// Off, it sees the selected iPad's counts. Settings failures use the normal default.
    public func usesEveryMacCore(_ bundleIdentifier: String) -> Bool {
        !SettingsStore(paths: paths).load(bundleIdentifier: bundleIdentifier).settings.mulg.identity.matchDeviceCPU
    }

    public func setUsesEveryMacCore(_ every: Bool, for bundleIdentifier: String) throws {
        try edit(bundleIdentifier) { $0.mulg.identity.matchDeviceCPU = !every }
    }

    /// Forced resolution (graphics.forceRenderResolution): the game renders at the selected resolution even
    /// when its own option picks less. Applies live.
    public func forcesRenderResolution(_ bundleIdentifier: String) -> Bool {
        SettingsStore(paths: paths).load(bundleIdentifier: bundleIdentifier).settings.mulg.graphics.forceRenderResolution
    }

    public func setForcesRenderResolution(_ forced: Bool, for bundleIdentifier: String) throws {
        try edit(bundleIdentifier) { $0.mulg.graphics.forceRenderResolution = forced }
    }

    public func usesNativeSceneResolution(_ bundleIdentifier: String) -> Bool {
        SettingsStore(paths: paths).load(bundleIdentifier: bundleIdentifier).settings.mulg.graphics.nativeSceneResolution
    }

    public func setUsesNativeSceneResolution(_ enabled: Bool, for bundleIdentifier: String) throws {
        try edit(bundleIdentifier) { $0.mulg.graphics.nativeSceneResolution = enabled }
    }

    /// Retina (display.retina): off, the game sees a 1x screen of the same point size. Applies at restart.
    public func usesRetina(_ bundleIdentifier: String) -> Bool {
        SettingsStore(paths: paths).load(bundleIdentifier: bundleIdentifier).settings.mulg.display.retina
    }

    public func setUsesRetina(_ retina: Bool, for bundleIdentifier: String) throws {
        try edit(bundleIdentifier) { $0.mulg.display.retina = retina }
    }

    /// The fixed resolutions the game menus offer: the iPad's own screen, native 4K, native 5K and
    /// this display's own pixels.
    public static let quickResolutions: [ResolutionMode] = [.matchDevice, .native4K, .native5K, .display]

    /// Keep a game's existing mode selected even when it is not a quick preset.
    public static func resolutionOptions(current: ResolutionMode) -> [ResolutionMode] {
        quickResolutions.contains(current) ? quickResolutions : [current] + quickResolutions
    }

    public func resolution(_ bundleIdentifier: String) -> ResolutionMode {
        ResolutionMode(setting: SettingsStore(paths: paths).load(bundleIdentifier: bundleIdentifier).settings.resolution)
    }

    /// Sets one of `quickResolutions`, with its window size and 2× scale. Keymaps follow by themselves.
    public func setResolution(_ mode: ResolutionMode, for bundleIdentifier: String) throws {
        guard Self.quickResolutions.contains(mode) else { return }
        try edit(bundleIdentifier) { settings in
            let size = ResolutionCalculator.windowSize(mode: mode, aspect: .sixteenByNine, mainScreen: (0, 0),
                                                       screenHasNotch: false, custom: (0, 0),
                                                       device: DeviceScreen.forDevice(settings.iosDeviceModel))
            settings.resolution = mode.rawValue
            (settings.windowWidth, settings.windowHeight) = size
            settings.customScaler = 2
            if mode == .display, let screen = NSScreen.main {
                // The display's own pixels, notch area left out as full screen does. Its refresh rate is
                // followed at runtime (DisplayModule.effectiveDisplay).
                let height = ResolutionCalculator.heightAvoidingNotch(width: Int(screen.frame.width),
                    height: Int(screen.frame.height), hasNotch: screen.safeAreaInsets.top > 0)
                (settings.windowWidth, settings.windowHeight) = (Int(screen.frame.width), height)
                settings.customScaler = screen.backingScaleFactor
            }
        }
    }

    /// The host coordinates runtime refresh, signing, credentials and session monitoring.
    public func launch(_ bundleIdentifier: String, profile: PerformanceProfile? = nil) throws {
        let bundle = app(bundleIdentifier)
        guard GameSessionLease.isValidBundleIdentifier(bundleIdentifier),
              FileManager.default.fileExists(atPath: bundle.path) || BundleTransaction.hasPendingRecovery(bundleIdentifier, paths: paths)
        else { throw Failure.notInstalled(bundleIdentifier) }
        var request = URLComponents()
        request.scheme = "mulgapp"
        request.host = "app"
        request.queryItems = [URLQueryItem(name: "action", value: "open"),
                              URLQueryItem(name: "id", value: bundleIdentifier)]
        if let profile { request.queryItems?.append(URLQueryItem(name: "profile", value: profile.rawValue)) }
        guard let url = request.url else { throw Failure.notInstalled(bundleIdentifier) }
        try Command.run("/usr/bin/open", [url.absoluteString])
    }
}

extension PerformanceProfile {
    /// The names the `mulg` command accepts: "120", "balanced", "battery" and the raw values.
    public init?(argument: String) {
        switch argument.lowercased() {
        case "120", "fps120": self = .fps120
        case "balanced": self = .balanced
        case "battery", "batterysaver": self = .batterySaver
        default: return nil
        }
    }
}
#endif
