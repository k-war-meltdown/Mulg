// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MulgContracts
import MulgLibrary

/// One setting a preset changed, shown to the user after applying it (PLAN.md §7).
public struct SettingChange: Sendable, Equatable, Identifiable {
    /// The settings key, `<module>.<key>` or an upstream key.
    public let key: String
    public let title: String
    public let old: String
    public let new: String

    public var id: String { key }
}

/// The named profiles on the Performance tab (PLAN.md §7, §13.1).
public enum PerformanceProfile: String, Sendable, CaseIterable, Identifiable {
    case fps120, balanced, batterySaver

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fps120: String(localized: "120 FPS: iPad Pro M5", bundle: .module)
        case .balanced: String(localized: "Balanced", bundle: .module)
        case .batterySaver: String(localized: "Battery saver", bundle: .module)
        }
    }
}

/// The profile buttons on the Performance tab (PLAN.md §7).
public enum PerformancePreset {
    public static let deviceModel = "iPad17,3"

    /// The 120 FPS profile.
    public static func apply120FPS(to settings: inout GameSettings) -> [SettingChange] {
        apply(.fps120, to: &settings)
    }

    /// Applies a profile and lists what changed. Settings already at the profile's value are
    /// left out. The Games category lives in the game's Info.plist, so it is not part of
    /// `settings`; `needsGamesCategory` tells the app to set it with
    /// `GameInstaller.setCategory` and sign the game again.
    ///
    /// Balanced and Battery saver leave the device identity alone: they only lower the load.
    /// `batteryCap` is the battery saver's frame-rate cap, 60 or 30 (§7). Keys in `keeping` are left as
    /// the user has them, for a preview where they unticked a change.
    // ponytail: profiles are the three built-ins; user-made and exported profiles are the
    // game's settings file (SettingsStore), copied by hand until someone asks for more.
    public static func apply(_ profile: PerformanceProfile, to settings: inout GameSettings,
                             batteryCap: Int = 60, keeping: Set<String> = [],
                             runningStates: [String: String]? = nil) -> [SettingChange] {
        var changes: [SettingChange] = []
        func set<Value: Equatable>(_ path: WritableKeyPath<GameSettings, Value>, _ value: Value,
                                   key: String, title: String) {
            let old = settings[keyPath: path]
            guard old != value, !keeping.contains(key) else { return }
            let owner: ModuleID = key == "iosDeviceModel" ? .identity
                : key == "limitMotionUpdateFrequency" ? .controls
                : key.hasPrefix("graphics.") ? .graphics : .display
            guard ModuleRow.unavailabilityReason(owner, settings: settings, runningStates: runningStates) == nil else { return }
            settings[keyPath: path] = value
            changes.append(SettingChange(key: key, title: title, old: "\(old)", new: "\(value)"))
        }
        let proMotion = String(localized: "Report a 120 Hz ProMotion screen", bundle: .module)
        let uncap = String(localized: "Allow frame rates above 60", bundle: .module)
        let belowRefresh = String(localized: "Cap just below the refresh rate", bundle: .module)
        let cap = String(localized: "Frame-rate cap", bundle: .module)
        switch profile {
        case .fps120:
            set(\.iosDeviceModel, deviceModel, key: "iosDeviceModel",
                title: String(localized: "Device identity: iPad Pro 13-inch (M5)", bundle: .module))
            set(\.mulg.display.reportProMotion, true, key: "display.reportProMotion", title: proMotion)
            set(\.mulg.display.uncapFrameRate, true, key: "display.uncapFrameRate", title: uncap)
            set(\.mulg.display.frameCapBelowRefresh, false, key: "display.frameCapBelowRefresh", title: belowRefresh)
            set(\.mulg.display.frameRateCap, 0, key: "display.frameRateCap", title: cap)
            set(\.mulg.graphics.fullScreenPerformanceMode, true, key: "graphics.fullScreenPerformanceMode",
                title: String(localized: "Full-screen performance mode", bundle: .module))
            set(\.resolution, ResolutionMode.matchDevice.rawValue, key: "resolution",
                title: String(localized: "Resolution: match the iPad Pro screen", bundle: .module))
            set(\.limitMotionUpdateFrequency, true, key: "limitMotionUpdateFrequency",
                title: String(localized: "Limit motion sensor updates", bundle: .module))
        case .balanced:
            set(\.mulg.display.uncapFrameRate, true, key: "display.uncapFrameRate", title: uncap)
            set(\.mulg.display.frameCapBelowRefresh, true, key: "display.frameCapBelowRefresh", title: belowRefresh)
            set(\.mulg.display.frameRateCap, 0, key: "display.frameRateCap", title: cap)
            set(\.resolution, ResolutionMode.p1440.rawValue, key: "resolution",
                title: String(localized: "Resolution: 1440p", bundle: .module))
        case .batterySaver:
            set(\.mulg.display.reportProMotion, false, key: "display.reportProMotion", title: proMotion)
            set(\.mulg.display.uncapFrameRate, false, key: "display.uncapFrameRate", title: uncap)
            set(\.mulg.display.frameCapBelowRefresh, false, key: "display.frameCapBelowRefresh", title: belowRefresh)
            set(\.mulg.display.frameRateCap, batteryCap, key: "display.frameRateCap", title: cap)
            set(\.resolution, ResolutionMode.p1080.rawValue, key: "resolution",
                title: String(localized: "Resolution: 1080p", bundle: .module))
        }
        return changes
    }

    public static func needsGamesCategory(currentCategory: String?) -> Bool {
        currentCategory != GameInstaller.gamesCategory
    }
}

/// When a setting reaches a game that is already running (PLAN.md §7).
public enum ApplyTiming: Sendable {
    case live, restart, reinstall

    public var label: String {
        switch self {
        case .live: String(localized: "Applies live", bundle: .module)
        case .restart: String(localized: "Restart game", bundle: .module)
        case .reinstall: String(localized: "Reinstall required", bundle: .module)
        }
    }
}

public enum RestartSettings {
    private static var all: [(title: String, changed: (GameSettings, GameSettings) -> Bool)] {
        [
            option(String(localized: "Report iPad Pro 120 Hz capability", bundle: .module), \.mulg.display.reportProMotion),
            option(String(localized: "Keep compiled shaders between launches and reinstalls", bundle: .module), \.mulg.graphics.shaderArchive),
            option(String(localized: "Metal performance HUD", bundle: .module), \.metalHUD),
            option(String(localized: "Modules", bundle: .module), \.mulg.engine.disabledModules),
            option(String(localized: "Environment variables", bundle: .module), \.mulg.engine.environment),
            option("Report all available Mac CPU cores", \.mulg.identity.matchDeviceCPU),
            option("Maximize parallel shader compilation", \.mulg.engine.maximizeShaderCompilation),
            option("Audio output format", \.mulg.engine.audioOutput),
            option("Automatic recovery", \.mulg.engine.automaticRecovery)
        ]
    }

    private static func option<Value: Equatable>(_ title: String, _ path: KeyPath<GameSettings, Value>)
        -> (title: String, changed: (GameSettings, GameSettings) -> Bool) {
        (title, { $0[keyPath: path] != $1[keyPath: path] })
    }

    /// The titles of the restart options that differ between the two settings.
    public static func pending(from old: GameSettings, to new: GameSettings) -> [String] {
        all.filter { $0.changed(old, new) }.map(\.title)
    }
}

/// The checks shown before launch (PLAN.md §7).
public struct ReadinessCheck: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable { case ok, warning, failed }

    public let id: String
    public let title: String
    public let state: State

    /// What the Mac and the game look like right now. The app fills this in from
    /// `NSScreen.maximumFramesPerSecond`, `ProcessInfo.isLowPowerModeEnabled` and the
    /// game's Info.plist.
    public struct Inputs: Sendable {
        public var refreshRate: Int
        public var lowPowerMode: Bool
        public var mainScreen: (width: Int, height: Int)
        public var screenHasNotch: Bool
        public var category: String?

        public init(refreshRate: Int, lowPowerMode: Bool, mainScreen: (width: Int, height: Int),
                    screenHasNotch: Bool, category: String?) {
            self.refreshRate = refreshRate
            self.lowPowerMode = lowPowerMode
            self.mainScreen = mainScreen
            self.screenHasNotch = screenHasNotch
            self.category = category
        }
    }

    public static func run(_ inputs: Inputs, settings: GameSettings) -> [ReadinessCheck] {
        let window = ResolutionCalculator.windowSize(
            mode: ResolutionMode(setting: settings.resolution),
            aspect: AspectRatioChoice(setting: settings.aspectRatio),
            mainScreen: inputs.mainScreen,
            screenHasNotch: inputs.screenHasNotch,
            custom: (settings.windowWidth, settings.windowHeight),
            device: DeviceScreen.forDevice(settings.iosDeviceModel)
        )
        let heavy = ResolutionCalculator.exceedsWarning(width: window.width, height: window.height,
                                                        scaler: settings.customScaler)
        // ponytail: "known" means the device catalogue knows the ID; per-game results (§3.5)
        // replace this once they exist.
        let knownDevice = DeviceScreen.byDevice[settings.iosDeviceModel] != nil
        // Native CPU counts and interface idiom are deliberate compatibility choices.
        let identityMatches = settings.mulg.identity.macAnswers.allSatisfy {
            $0 == "identity.matchDeviceCPU" || $0 == "identity.matchMobileInterface"
        }
        return [
            ReadinessCheck(id: "refresh", title: String(localized: "Display refreshes at 120 Hz or more", bundle: .module),
                           state: inputs.refreshRate >= 120 ? .ok : .failed),
            ReadinessCheck(id: "lowPower", title: String(localized: "Low Power Mode is off", bundle: .module),
                           state: inputs.lowPowerMode ? .failed : .ok),
            ReadinessCheck(id: "frameCap", title: String(localized: "No frame-rate cap below 120", bundle: .module),
                           state: (1..<120).contains(settings.mulg.display.frameRateCap) ? .warning : .ok),
            ReadinessCheck(id: "renderLoad", title: String(localized: "Render load is moderate", bundle: .module),
                           state: heavy ? .warning : .ok),
            ReadinessCheck(id: "device", title: String(localized: "Device identity is a known device", bundle: .module),
                           state: knownDevice ? .ok : .warning),
            // Any other resolution shows the game a screen no iPad has, next to an iPad model.
            ReadinessCheck(id: "screen", title: String(localized: "Screen matches the device identity", bundle: .module),
                           state: ResolutionMode(setting: settings.resolution) == .matchDevice ? .ok : .warning),
            // A switched-off identity setting lets the Mac answer next to the iPad model.
            ReadinessCheck(id: "identity", title: String(localized: "Every device answer matches the device identity", bundle: .module),
                           state: settings.mulg.engine.isModuleEnabled(.identity) && identityMatches ? .ok : .warning),
            ReadinessCheck(id: "category", title: String(localized: "Games category (Game Mode) is set", bundle: .module),
                           state: PerformancePreset.needsGamesCategory(currentCategory: inputs.category) ? .warning : .ok)
        ]
    }
}

public struct ModuleRow: Sendable, Equatable, Identifiable {
    public let module: ModuleID
    public let enabled: Bool
    /// Essential modules are always on and their switch is disabled.
    public let locked: Bool

    public var id: ModuleID { module }

    /// Plain-language name and one sentence on what the module controls.
    public var title: String {
        switch module {
        case .engine: String(localized: "Core", bundle: .module)
        case .identity: String(localized: "Device identity", bundle: .module)
        case .display: String(localized: "Display and frame rate", bundle: .module)
        case .graphics: String(localized: "Graphics and MetalFX", bundle: .module)
        case .controls: String(localized: "Controls", bundle: .module)
        case .bridge: String(localized: "Mac window link", bundle: .module)
        case .diagnostics: String(localized: "Debugger and diagnostics", bundle: .module)
        case .integrations: String(localized: "Keychain and Discord", bundle: .module)
        default: module.rawValue
        }
    }

    public var summary: String {
        switch module {
        case .engine: String(localized: "Starts the other modules and passes settings changes and window closing to the game.", bundle: .module)
        case .identity: String(localized: "Decides which device the game thinks it is running on: model, screen and system details.", bundle: .module)
        case .display: String(localized: "Sets the frame rate, refresh rate, window size and the battery and heat limits.", bundle: .module)
        case .graphics: String(localized: "Adds MetalFX upscaling, vsync control and smoother frame pacing.", bundle: .module)
        case .controls: String(localized: "Turns keyboard, mouse and controller input into what the game expects.", bundle: .module)
        case .bridge: String(localized: "Lets the game use the Mac's windows, cursor and input.", bundle: .module)
        case .diagnostics: String(localized: "Writes the debug log, shows the performance overlay and keeps crash reports.", bundle: .module)
        case .integrations: String(localized: "Keeps the game's saved logins in Mulg's own keychain and shows what you play on Discord.", bundle: .module)
        default: ""
        }
    }

    /// Why the switch cannot be turned off; nil when it can.
    public var lockReason: String? {
        guard locked else { return nil }
        switch module {
        case .bridge: return String(localized: "Always on: without it the game gets no window or input.", bundle: .module)
        default: return String(localized: "Always on: every other module depends on it.", bundle: .module)
        }
    }
    /// Shown with a badge; safe mode switches experimental modules off (§1.5 rule 10).
    public var isExperimental: Bool { module.cardStatus == "experimental" }

    public static func unavailabilityReason(_ module: ModuleID, settings: GameSettings,
                                            runningStates: [String: String]? = nil) -> String? {
        if !settings.mulg.engine.isModuleEnabled(module) {
            return String(localized: "Disabled in Modules. Enable the module and restart the game to use these options.", bundle: .module)
        }
        guard let runningStates else { return nil }
        guard let state = runningStates[module.rawValue] else {
            return String(localized: "Runtime status is unavailable. Restart the game before changing these options.", bundle: .module)
        }
        if state == "active" || state == "prepared" || state.hasPrefix("degraded(") { return nil }
        return String(localized: "Unavailable in this game session. Check Modules and recovery settings, then restart the game.", bundle: .module)
    }

    /// Reads only the existing diagnostics contract; GUI never imports game-side modules.
    static func runningStates(from data: Data, processIdentifiers: Set<Int32>) -> [String: String] {
        struct Startup: Decodable {
            struct Module: Decodable { let id: String; let state: String }
            let processIdentifier: Int32
            let modules: [Module]
        }
        guard let report = try? JSONDecoder().decode(Startup.self, from: data),
              processIdentifiers.contains(report.processIdentifier) else { return [:] }
        return report.modules.reduce(into: [:]) { $0[$1.id] = $1.state }
    }

    public static func rows(for settings: GameSettings) -> [ModuleRow] {
        ModuleID.allCases.filter(\.runsInGame).sorted().map { module in
            ModuleRow(module: module, enabled: settings.mulg.engine.isModuleEnabled(module), locked: module.isEssential)
        }
    }

    public static func set(_ module: ModuleID, enabled: Bool, in settings: inout GameSettings) {
        guard !module.isEssential else { return }
        var disabled = Set(settings.mulg.engine.disabledModules)
        if enabled {
            disabled.remove(module.rawValue)
        } else {
            disabled.insert(module.rawValue)
        }
        settings.mulg.engine.disabledModules = disabled.sorted()
    }
}

public enum OnlineWarning {
    public enum Feature: String, Sendable, CaseIterable {
        case deviceIdentity, metalFX, virtualController, cameraReach, compatibilityBypass
    }

    /// Features that `after` turns on compared with `before`.
    public static func featuresTurnedOn(before: GameSettings, after: GameSettings) -> [Feature] {
        var features: [Feature] = []
        if before.iosDeviceModel != after.iosDeviceModel {
            features.append(.deviceIdentity)
        }
        if !before.mulg.graphics.metalFX.enabled && after.mulg.graphics.metalFX.enabled {
            features.append(.metalFX)
        }
        if before.mulg.controls.playMode == .touch && after.mulg.controls.playMode != .touch {
            features.append(.virtualController)
        }
        if !before.mulg.camera.extendedReach && after.mulg.camera.extendedReach {
            features.append(.cameraReach)
        }
        if (!before.mulg.identity.environmentBypass && after.mulg.identity.environmentBypass)
            || (!before.bypass && after.bypass) { features.append(.compatibilityBypass) }
        return features
    }

    // ponytail: the app cannot tell an online game from an offline one, so every game gets
    // the warning once per feature. Skip offline games when the store knows which are online.
    static func defaultsKey(_ feature: Feature, bundleIdentifier: String) -> String {
        "gui.onlineWarningShown.\(feature.rawValue).\(bundleIdentifier)"
    }

    /// True once the warning has been shown for this game. Shortcuts cannot show it, so
    /// they only turn on features the user has already been warned about.
    public static func wasShown(_ feature: Feature, bundleIdentifier: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey(feature, bundleIdentifier: bundleIdentifier))
    }

    /// Features to warn about now; each is recorded so it is shown only once per game.
    public static func pending(_ features: [Feature], bundleIdentifier: String,
                               defaults: UserDefaults = .standard) -> [Feature] {
        features.filter { feature in
            let key = defaultsKey(feature, bundleIdentifier: bundleIdentifier)
            guard !defaults.bool(forKey: key) else { return false }
            defaults.set(true, forKey: key)
            return true
        }
    }

    public static func message(for feature: Feature) -> String {
        switch feature {
        case .deviceIdentity:
            String(localized: "The game will see an iPad Pro instead of a Mac. Online games may treat this as breaking their terms and could flag your account. Try it on a secondary account first.", bundle: .module)
        case .metalFX:
            String(localized: "The MetalFX layer changes how the game's image reaches the screen. Online games with anti-cheat may react to it. Try it on a secondary account first.", bundle: .module)
        case .virtualController:
            String(localized: "The virtual controller makes the game see a game controller. Some online games treat controller players differently or restrict it. Try it on a secondary account first.", bundle: .module)
        case .compatibilityBypass:
            String(localized: "Compatibility bypasses changes device information and known SDK environment checks for this game. It may not resolve a game's integrity restriction, and online games may flag or restrict your account.", bundle: .module)
        case .cameraReach:
            String(localized: "Camera reach changes the game's own memory to raise its zoom limit. Online games such as Genshin Impact and Honkai: Star Rail forbid modifying the game, and this MAY GET YOUR ACCOUNT BANNED. Use it at your own risk, ideally on an account you can afford to lose.", bundle: .module)
        }
    }
}
#endif
