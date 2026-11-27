#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import MulgContracts
import SwiftUI

/// The parts of a game's settings. Each is one tab of a sidebar page (`GameSettingsPage`), and the unit
/// "Reset" restores.
public enum GameSettingsSection: String, CaseIterable, Identifiable {
    // Play
    case display, graphics, unlocks, power, sound
    // Input
    case controls, keymapOptions
    // Data
    case storage, privacy
    // Advanced
    case runtime, device, bypasses, startup, debugging, info

    public var id: String { rawValue }

    public enum Group: String, CaseIterable, Identifiable {
        case play = "Play", input = "Input", data = "Data", advanced = "Advanced"
        public var id: String { rawValue }
        public var sections: [GameSettingsSection] { GameSettingsSection.allCases.filter { $0.group == self } }
    }

    public var group: Group {
        switch self {
        case .display, .graphics, .unlocks, .power, .sound: .play
        case .controls, .keymapOptions: .input
        case .storage, .privacy: .data
        case .runtime, .device, .bypasses, .startup, .debugging, .info: .advanced
        }
    }

    public var title: String {
        switch self {
        case .display: "Display"
        case .graphics: "Graphics & frame rate"
        case .power: "Battery & heat"
        case .sound: "Sound"
        case .controls: "Controls"
        case .keymapOptions: "Keymap options"
        case .unlocks: "Game unlocks"
        case .storage: "Storage & saves"
        case .privacy: "Privacy"
        case .runtime: "Runtime"
        case .device: "Device & fixes"
        case .bypasses: "Compatibility bypasses"
        case .startup: "Startup & plugins"
        case .debugging: "Debugging"
        case .info: "App info"
        }
    }

    public var symbol: String {
        switch self {
        case .display: "display"
        case .graphics: "sparkles.tv"
        case .power: "battery.75percent"
        case .sound: "speaker.wave.2"
        case .controls: "keyboard"
        case .keymapOptions: "slider.horizontal.3"
        case .unlocks: "lock.open"
        case .storage: "externaldrive"
        case .privacy: "hand.raised"
        case .runtime: "shippingbox"
        case .device: "ipad.landscape"
        case .bypasses: "switch.2"
        case .startup: "power"
        case .debugging: "ladybug"
        case .info: "info.circle"
        }
    }

    public var subtitle: String {
        switch self {
        case .display: "Resolution, proportions and how the window behaves."
        case .graphics: "Performance profiles, MetalFX, frame-rate limits and graphics options."
        case .power: "Playing in the background, on battery and when the Mac is hot."
        case .sound: "The audio format of your output device while the game runs."
        case .controls: "Play mode, your keymap, the control mapper, mouse, controllers and gyro."
        case .keymapOptions: "How keys, the mouse and the scroll wheel reach the game."
        case .unlocks: "Unlock 120 FPS and zoom the camera out farther than the game allows."
        case .storage: "Game files, downloaded data, save backups and reports."
        case .privacy: "What the game may use, and its saved logins, walled off from your macOS Keychain."
        case .runtime: "Mulg's runtime in this game, its modules and experiments."
        case .device: "Which device the game sees, login storage and compatibility fixes."
        case .bypasses: "Optional environment and known SDK compatibility checks, saved for this game."
        case .startup: "App category, Discord, startup options and custom plugins."
        case .debugging: "Performance HUD, debug log and launching under a debugger."
        case .info: "Bundle details of the installed game."
        }
    }

    /// The colour of the page's icon (MulgIcon).
    public var tint: Color {
        switch self {
        case .display: MulgIconTint.blue
        case .graphics: MulgIconTint.purple
        case .power: MulgIconTint.green
        case .sound: MulgIconTint.pink
        case .controls: MulgIconTint.orange
        case .keymapOptions: MulgIconTint.yellow
        case .unlocks: MulgIconTint.teal
        case .storage: MulgIconTint.indigo
        case .privacy: MulgIconTint.blue
        case .runtime: MulgIconTint.brown
        case .device: MulgIconTint.gray
        case .bypasses: MulgIconTint.orange
        case .startup: MulgIconTint.accent
        case .debugging: MulgIconTint.red
        case .info: MulgIconTint.gray
        }
    }

    /// Whether the page has preferences "Reset section…" can restore.
    public var resettable: Bool { ![.storage, .info].contains(self) }

    /// Reset only this section's preferences; retain trust records, runtime versions and files.
    public func reset(_ settings: inout GameSettings) throws {
        let defaults = GameSettings(bundleIdentifier: settings.bundleIdentifier)
        let paths: [String]
        switch self {
        case .display:
            paths = ["disableTimeout", "displayRotation", "windowWidth", "windowHeight", "customScaler",
                     "resolution", "aspectRatio", "inverseScreenValues", "windowFixMethod", "hideTitleBar",
                     "floatingWindow", "resizableAspectRatioType", "resizableAspectRatioWidth",
                     "resizableAspectRatioHeight", "mulg.display.reportHDRHeadroom", "mulg.display.retina", "mulg.graphics.forceRenderResolution",
                     "mulg.graphics.nativeSceneResolution"]
        case .graphics:
            paths = ["mulg.graphics", "mulg.display.frameRateCap", "mulg.display.lowLatency", "mulg.display.frameCapBelowRefresh",
                     "mulg.engine.maximizeShaderCompilation", "mulg.engine.prioritizeGameThreads",
                     "mulg.identity.matchDeviceCPU"]
        case .power:
            paths = ["mulg.engine.keepRunningUnfocused", "mulg.engine.confirmQuitShortcut", "mulg.engine.keepForegroundOnOtherSpaces", "mulg.engine.muteWhenUnfocused", "mulg.display.backgroundThrottle", "mulg.display.backgroundFrameRate",
                     "mulg.display.batterySaverOnBattery", "mulg.display.batteryFrameRateCap",
                     "mulg.display.thermalGuard", "mulg.display.thermalFrameRateCap"]
        case .sound: paths = ["mulg.engine.audioOutput"]
        case .controls: paths = ["mulg.controls", "mulg.mapper", "mulg.engine.confinePointer"]
        case .keymapOptions:
            paths = ["keymapping", "sensitivity", "noKMOnInput", "enableScrollWheel", "disableBuiltinMouse",
                     "limitMotionUpdateFrequency"]
        case .unlocks: paths = ["mulg.display.uncapFrameRate", "mulg.display.reportProMotion", "mulg.camera"]
        case .privacy: paths = ["mulg.privacy", "mulg.controls.automaticHUDAnchoring", "mulgChain", "mulgChainDebugging"]
        case .runtime:
            paths = ["mulg.engine.automaticRecovery", "mulg.engine.disabledModules", "mulg.engine.allowUnverifiedPlugins",
                     "mulg.engine.keepGameSDKVersion", "mulg.engine.memoryWarnings", "mulg.engine.readAhead",
                     "mulg.engine.environment", "mulg.engine.shutdownGraceSeconds", "mulg.engine.shutdownDeadlineSeconds"]
        case .device:
            paths = ["iosDeviceModel", "checkMicPermissionSync", "blockSleepSpamming",
                     "ignoreUnityKeyboardInitializationError", 
                     "mulg.integrations.authenticationCompatibility",
                     "mulg.identity.limitMemoryToDevice", "mulg.identity.genericDeviceName", "mulg.identity.presentAsIPad",
                     "mulg.identity.reportDeviceGPUName", "mulg.identity.matchDeviceCPU", "mulg.identity.deviceConfiguration"]
        case .bypasses: paths = ["bypass", "mulg.identity.environmentBypass", "mulg.identity.deviceConfiguration",
                                "mulg.identity.matchMobileInterface", "mulg.engine.automaticRecovery"]
        case .startup: paths = ["injectIntrospection", "rootWorkDir", "discordActivity"]
        case .debugging: paths = ["metalHUD", "mulg.diagnostics"]
        case .storage, .info: return // Nothing to reset: files and facts, not preferences.
        }
        let encoder = JSONEncoder()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(settings)) as! [String: Any]
        let source = try JSONSerialization.jsonObject(with: encoder.encode(defaults)) as! [String: Any]
        func replace(_ path: ArraySlice<String>, in target: inout [String: Any], from original: [String: Any]) {
            guard let key = path.first else { return }
            if path.count == 1 { target[key] = original[key]; return }
            var nested = target[key] as? [String: Any] ?? [:]
            replace(path.dropFirst(), in: &nested, from: original[key] as? [String: Any] ?? [:])
            target[key] = nested
        }
        for path in paths { replace(path.split(separator: ".").map(String.init)[...], in: &object, from: source) }
        settings = try JSONDecoder().decode(GameSettings.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

public enum GameSettingState: String {
    case applied = "Applied", restart = "Restart required", unsupported = "Unsupported"
    case recovery = "Disabled by recovery", disabled = "Module disabled", pending = "Applying…"
    case unconfirmed = "Awaiting runtime", reinstall = "Reinstall required"
    var color: Color {
        switch self {
        case .applied: .secondary
        case .unsupported, .recovery, .restart, .reinstall: .orange
        case .disabled, .pending, .unconfirmed: .secondary
        }
    }
}

public struct GameSettingsPresentation: Sendable {
    public var settings: GameSettings?
    public var runtime: RuntimeSettingsReport?
    public var running = false
    public var modular = true
    public var states: [String: String] = [:]
    public init() {}

    public func state(key: String?, timing: ApplyTiming, owner: ModuleID?, modularOnly: Bool = false) -> GameSettingState {
        if !modular && (modularOnly || (key?.hasPrefix("mulg.") == true && key != "mulg.display.reportProMotion")) {
            return .unsupported
        }
        if key == "mulg.engine.disabledModules", let owner, running, let runtime, let settings,
           settings.mulg.engine.isModuleEnabled(owner) != runtime.launch.mulg.engine.isModuleEnabled(owner) {
            return .restart
        }
        if let owner {
            let state = states[owner.rawValue] ?? ""
            let screenCore = owner == .display && ["resolution", "windowWidth", "windowHeight", "customScaler"].contains(key ?? "")
                && settings.map { $0.targetRenderHeight != nil } == true
            if !screenCore {
                if state.contains("offInSafeMode") { return .recovery }
                if state.contains("unavailable") { return .unsupported }
                if state.contains("switchedOff") || ((!running || state.isEmpty) && settings?.mulg.engine.isModuleEnabled(owner) == false) {
                    return .disabled
                }
            }
        }
        guard running else { return timing == .reinstall ? .reinstall : .applied }
        guard let key, let settings else { return timing == .live ? .unconfirmed : .restart }
        guard let runtime else { return timing == .live ? .unconfirmed : .restart }
        let baseline = timing == .live ? runtime.acknowledged : runtime.launch
        if value(key, in: settings) == value(key, in: baseline) { return .applied }
        switch timing {
        case .live: return .pending
        case .restart: return .restart
        case .reinstall: return .reinstall
        }
    }

    private func value(_ path: String, in settings: GameSettings) -> Data? {
        // The identity preset derives effective options without mutating preferences.
        // Badges must compare the behavior requested now with the launch's behavior,
        // even when both saved independent toggles have the same raw value.
        var compared = settings
        if path.hasPrefix("mulg.identity.") {
            compared.mulg.identity = settings.mulg.identity.effective
        }
        guard let data = try? JSONEncoder().encode(compared),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let value = path.split(separator: ".").reduce(object as Any?) { object, key in
            (object as? [String: Any])?[String(key)]
        }
        return value.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
    }
}

private struct PresentationKey: EnvironmentKey { static let defaultValue = GameSettingsPresentation() }
public extension EnvironmentValues {
    var gameSettingsPresentation: GameSettingsPresentation {
        get { self[PresentationKey.self] }
        set { self[PresentationKey.self] = newValue }
    }
}

public struct GameSettingBadge: View {
    @Environment(\.gameSettingsPresentation) private var presentation
    let key: String?
    let timing: ApplyTiming
    let owner: ModuleID?
    let modularOnly: Bool
    public init(_ key: String?, timing: ApplyTiming = .restart, owner: ModuleID? = nil, modularOnly: Bool = false) {
        self.key = key; self.timing = timing; self.owner = owner; self.modularOnly = modularOnly
    }
    public var body: some View {
        let state = presentation.state(key: key, timing: timing, owner: owner, modularOnly: modularOnly)
        Text(state.rawValue).font(.caption2).foregroundStyle(state.color)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(state.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
            .help(!presentation.running && state == .applied ? "Saved for the next launch."
                  : state == .applied ? "The runtime has acknowledged this configuration."
                  : state == .unconfirmed ? "This running runtime has not supplied a settings acknowledgement."
                  : timing.label)
    }
}

public struct GameSettingLabel: View {
    let title: String
    let key: String?
    let timing: ApplyTiming
    let owner: ModuleID?
    let modularOnly: Bool
    public init(_ title: String, key: String?, timing: ApplyTiming = .restart, owner: ModuleID? = nil, modularOnly: Bool = false) {
        self.title = title; self.key = key; self.timing = timing; self.owner = owner; self.modularOnly = modularOnly
    }
    public var body: some View {
        HStack(spacing: 8) {
            Text(title)
            GameSettingBadge(key, timing: timing, owner: owner, modularOnly: modularOnly)
        }
    }
}
#endif
