import Foundation

/// Settings added by this fork, stored under the `mulg` key of a game's settings file.
///
/// One nested value per module, so every setting has an owner (PLAN.md §1.5 rule 3).
/// Every field has a default and every decoder tolerates missing keys, so adding a
/// setting never breaks existing files.
public struct ModuleSettings: Codable, Sendable, Equatable {
    public var display: DisplaySettings = DisplaySettings()
    public var graphics: GraphicsSettings = GraphicsSettings()
    public var controls: ControlsSettings = ControlsSettings()
    public var engine: EngineSettings = EngineSettings()
    public var diagnostics: DiagnosticsSettings = DiagnosticsSettings()
    public var identity: IdentitySettings = IdentitySettings()
    public var mapper: MapperSettings = MapperSettings()
    public var camera: CameraSettings = CameraSettings()
    public var privacy: PrivacySettings = PrivacySettings()
    public var integrations: IntegrationsSettings = IntegrationsSettings()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case display, graphics, controls, engine, diagnostics, identity, mapper, camera, integrations, privacy
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ModuleSettings()
        display = try c.value(.display, default: d.display)
        graphics = try c.value(.graphics, default: d.graphics)
        controls = try c.value(.controls, default: d.controls)
        engine = try c.value(.engine, default: d.engine)
        diagnostics = try c.value(.diagnostics, default: d.diagnostics)
        identity = try c.value(.identity, default: d.identity)
        mapper = try c.value(.mapper, default: d.mapper)
        camera = try c.value(.camera, default: d.camera)
        privacy = try c.value(.privacy, default: d.privacy)
        integrations = try c.value(.integrations, default: d.integrations)
    }
}

public struct IntegrationsSettings: Codable, Sendable, Equatable {
    /// Native provider presentation and web-session lifetime repair; captured at launch.
    public var authenticationCompatibility = true
    public init() {}
    enum CodingKeys: String, CodingKey { case authenticationCompatibility }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authenticationCompatibility = try c.value(.authenticationCompatibility, default: true)
    }
}

// MARK: - mapper

/// The control mapper: the overlay where controls are drawn on the game and bound to keys.
public struct MapperSettings: Codable, Sendable, Equatable {
    public static let tintRange: ClosedRange<Double> = 0.1...0.6

    /// How dark the layer over the game is while mapping, so controls stand out on any scene.
    public var tintOpacity: Double = 0.3
    /// Short tips at the bottom of the screen while mapping.
    public var showTips: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey { case tintOpacity, showTips }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MapperSettings()
        let tint = try c.value(.tintOpacity, default: d.tintOpacity)
        tintOpacity = tint.isFinite ? min(max(tint, Self.tintRange.lowerBound), Self.tintRange.upperBound) : d.tintOpacity
        showTips = try c.value(.showTips, default: d.showTips)
    }
}

extension KeyedDecodingContainer {
    /// Decodes a string-backed enum, falling back to `fallback` for missing or unknown
    /// values (for example a value written by a newer version).
    func enumValue<T: RawRepresentable>(_ key: Key, default fallback: T) throws -> T where T.RawValue == String {
        guard let raw = try decodeIfPresent(String.self, forKey: key) else {
            return fallback
        }
        return T(rawValue: raw) ?? fallback
    }
}

// MARK: - display (PLAN.md §4, §6.1, §13.1)

public struct DisplaySettings: Codable, Sendable, Equatable {
    /// Report 120 Hz to the game, but only when the current display supports it (§4.1). On by
    /// default, so games offer their 120 FPS option on every 120 Hz Mac display.
    public var reportProMotion: Bool = true
    /// Raise a game's own 60 FPS cap to the display maximum (§4.2).
    public var uncapFrameRate: Bool = true
    /// Keep at most one finished frame waiting: maximumDrawableCount = 2 (§6.1).
    public var lowLatency: Bool = false
    /// Cap slightly below the refresh rate, for example 116 FPS at 120 Hz (§6.1).
    public var frameCapBelowRefresh: Bool = false
    /// Cap a hidden or covered game at a low frame rate (§13.1).
    public var backgroundThrottle: Bool = false
    /// Frame rate while hidden, when `backgroundThrottle` is on.
    public var backgroundFrameRate: Int = 5
    /// Report a nominal thermal state to the game. Upstream MulgKit always did this, so it
    /// stays on by default to keep games behaving as before (§4.3); it can be turned off.
    public var reportNominalThermalState: Bool = true
    /// Hide Low Power Mode from the game. Upstream always did this; same reasoning.
    public var hideLowPowerMode: Bool = true
    /// Report the Mac display's real HDR headroom, on HDR-capable displays only (§13.1).
    public var reportHDRHeadroom: Bool = false
    /// Never draw faster than this; 0 means no cap. The battery saver profile sets 60 or 30 (§7).
    public var frameRateCap: Int = 120
    /// Switch to `batteryFrameRateCap` while the Mac runs on battery or in Low Power Mode, and
    /// back when neither holds (§7). The MetalFX layer also drops to its Performance preset.
    public var batterySaverOnBattery: Bool = false
    public var batteryFrameRateCap: Int = 60
    /// Cap at `thermalFrameRateCap` while the Mac's thermal state is serious or critical, until
    /// it cools down (§13.1). The game is usually told the state is nominal
    /// (`reportNominalThermalState`), so it never slows down by itself.
    public var thermalGuard: Bool = false // Off for new games (user choice); per game in Performance.
    public var thermalFrameRateCap: Int = 60
    /// Retina: the game sees a 2x (or the selected scale) screen and renders that many pixels. Off, it sees
    /// a 1x screen of the same point size, as on a non-Retina iPad, and renders one pixel per point.
    public var retina: Bool = true

    /// The cap in effect: the lowest of the fixed cap, the battery cap on battery and the thermal
    /// cap while hot. 0 is none.
    public func effectiveFrameRateCap(onBattery: Bool, hot: Bool = false) -> Int {
        let caps = [frameRateCap,
                    onBattery && batterySaverOnBattery ? batteryFrameRateCap : 0,
                    hot && thermalGuard ? thermalFrameRateCap : 0].filter { $0 > 0 }
        return caps.min() ?? 0
    }

    public init() {}

    enum CodingKeys: String, CodingKey {
        case reportProMotion, uncapFrameRate, lowLatency, frameCapBelowRefresh, backgroundThrottle
        case backgroundFrameRate, reportNominalThermalState, hideLowPowerMode, reportHDRHeadroom
        case frameRateCap, batterySaverOnBattery, batteryFrameRateCap, thermalGuard, thermalFrameRateCap, retina
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DisplaySettings()
        reportProMotion = try c.value(.reportProMotion, default: d.reportProMotion)
        uncapFrameRate = try c.value(.uncapFrameRate, default: d.uncapFrameRate)
        lowLatency = try c.value(.lowLatency, default: d.lowLatency)
        frameCapBelowRefresh = try c.value(.frameCapBelowRefresh, default: d.frameCapBelowRefresh)
        backgroundThrottle = try c.value(.backgroundThrottle, default: d.backgroundThrottle)
        backgroundFrameRate = try c.value(.backgroundFrameRate, default: d.backgroundFrameRate)
        reportNominalThermalState = try c.value(.reportNominalThermalState, default: d.reportNominalThermalState)
        hideLowPowerMode = try c.value(.hideLowPowerMode, default: d.hideLowPowerMode)
        reportHDRHeadroom = try c.value(.reportHDRHeadroom, default: d.reportHDRHeadroom)
        frameRateCap = try c.value(.frameRateCap, default: d.frameRateCap)
        batterySaverOnBattery = try c.value(.batterySaverOnBattery, default: d.batterySaverOnBattery)
        batteryFrameRateCap = try c.value(.batteryFrameRateCap, default: d.batteryFrameRateCap)
        thermalGuard = try c.value(.thermalGuard, default: d.thermalGuard)
        thermalFrameRateCap = try c.value(.thermalFrameRateCap, default: d.thermalFrameRateCap)
        retina = try c.value(.retina, default: d.retina)
    }
}

// MARK: - graphics (PLAN.md §5)

public enum MetalFXPreset: String, Codable, Sendable, CaseIterable {
    case quality, balanced, performance, ultraPerformance

    /// Render scale per side, in whole percent (§5.2.2). Integers avoid floating-point
    /// surprises such as 1600 × 0.59 = 943.99….
    public var renderPercent: Int {
        switch self {
        case .quality: 77
        case .balanced: 67
        case .performance: 59
        case .ultraPerformance: 50
        }
    }

    /// Render scale per side as a fraction, for display.
    public var renderScale: Double {
        Double(renderPercent) / 100
    }

    /// Render size for a given output size, rounded down to even numbers and never below 2.
    public func renderSize(forOutputWidth width: Int, height: Int) -> (width: Int, height: Int) {
        func scaled(_ value: Int) -> Int {
            let raw = value * renderPercent / 100
            return max(2, raw - raw % 2)
        }
        return (scaled(width), scaled(height))
    }

    /// Short label for notices, for example "Balanced (67 %)".
    public var label: String {
        let name = switch self {
        case .quality: "Quality"
        case .balanced: "Balanced"
        case .performance: "Performance"
        case .ultraPerformance: "Ultra performance"
        }
        return "\(name) (\(renderPercent) %)"
    }
}

public struct MetalFXSettings: Codable, Sendable, Equatable {
    /// The on/off switch for the MetalFX layer on top of the game (§5.2). Off by default.
    public var enabled: Bool = false
    public var preset: MetalFXPreset = .balanced
    /// In-game toggle, written as modifier names plus a key, for example "option+command+U".
    public var hotkey: String = "option+command+U"
    /// Switches MetalFX on for the rest of the launch when the game's frame rate stays unevenly
    /// below its target (the frame limit, else 60). Off by default; the saved switch is unchanged.
    public var automatic: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, preset, hotkey, automatic
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MetalFXSettings()
        enabled = try c.value(.enabled, default: d.enabled)
        preset = try c.enumValue(.preset, default: d.preset)
        hotkey = try c.value(.hotkey, default: d.hotkey)
        automatic = try c.value(.automatic, default: d.automatic)
    }
}

public struct GraphicsSettings: Codable, Sendable, Equatable {
    public var metalFX: MetalFXSettings = MetalFXSettings()
    /// Full-screen performance mode: opaque layer and no overlays, for direct-to-display (§5.4).
    public var fullScreenPerformanceMode: Bool = false
    /// Vsync off: lowest latency, but tearing (§5.4). Off by default.
    public var vsyncOff: Bool = false
    /// Requests user-interactive priority for the presentation thread; macOS chooses its cores
    /// (§16.4, X2). On by default. This does not pin threads or force every core to stay busy.
    public var raiseRenderThreadPriority: Bool = true
    /// Keeps the game's compiled shaders in a Metal binary archive in Mulg's own folder (§5.6), so
    /// shader stutter happens once and survives reinstalls and updates of the game. On by default.
    public var shaderArchive: Bool = true
    /// With a frame cap, the game waits before it reads input and starts a frame instead of after
    /// it finished, so frames show newer input (§6.1, like NVIDIA Reflex). On by default.
    public var justInTimeFrameStart: Bool = true
    /// Full resolution: a game never renders below the screen's pixel density on its own (an engine
    /// that picks a lower view scale from its device tables is raised to the native scale). On by
    /// default; MetalFX, set per game, is the only way to render smaller.
    public var fullResolution: Bool = true
    /// Requests the selected output size through the engine or its render view. A game may still
    /// render its private 3D scene at a smaller size. New games request the full desktop resolution.
    public var forceRenderResolution: Bool = true
    /// Ask a verified renderer API to match its internal scene scale to the selected output.
    /// Opt-in: unsupported engines retain their existing rendering; Off restores owned values.
    public var nativeSceneResolution: Bool = false
    /// Unity games with IL2CPP's exports run at Unity's highest quality level (QualitySettings), set through
    /// Unity itself, so the picture stays the engine's own. Off by default: it raises shadows, effects and
    /// anti-aliasing as well and can cost frame rate. A game that keeps setting its own level back wins.
    public var unityHighestQuality: Bool = false
    // Mulg never resizes a game's own images (internal 1:1, removed 2026-10-30): saved `forceInternalResolution`
    // and `internalResolutionUnsupported` keys are ignored.

    public init() {}

    enum CodingKeys: String, CodingKey {
        case metalFX, fullScreenPerformanceMode, vsyncOff, raiseRenderThreadPriority, shaderArchive, justInTimeFrameStart, fullResolution
        case forceRenderResolution, nativeSceneResolution, unityHighestQuality
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GraphicsSettings()
        metalFX = try c.value(.metalFX, default: d.metalFX)
        fullScreenPerformanceMode = try c.value(.fullScreenPerformanceMode, default: d.fullScreenPerformanceMode)
        vsyncOff = try c.value(.vsyncOff, default: d.vsyncOff)
        raiseRenderThreadPriority = try c.value(.raiseRenderThreadPriority, default: d.raiseRenderThreadPriority)
        shaderArchive = try c.value(.shaderArchive, default: d.shaderArchive)
        justInTimeFrameStart = try c.value(.justInTimeFrameStart, default: d.justInTimeFrameStart)
        fullResolution = try c.value(.fullResolution, default: d.fullResolution)
        forceRenderResolution = try c.value(.forceRenderResolution, default: d.forceRenderResolution)
        nativeSceneResolution = try c.value(.nativeSceneResolution, default: d.nativeSceneResolution)
        unityHighestQuality = try c.value(.unityHighestQuality, default: d.unityHighestQuality)
    }
}

// MARK: - controls (PLAN.md §6.1, §14)

public enum PlayMode: String, Codable, Sendable, CaseIterable {
    /// Keys and mouse become touches (today's keymapping).
    case touch
    /// Keyboard and mouse appear to the game as a game controller.
    case virtualController
    /// Camera by touch-drag, everything else by virtual controller.
    case hybrid
}

public enum CursorKeyBehaviour: String, Codable, Sendable, CaseIterable {
    /// Cursor shows while the key is held, like Genshin on PC (default).
    case hold
    /// Each press switches between camera and cursor (upstream behaviour).
    case toggle
}

public enum GyroSource: String, Codable, Sendable, CaseIterable {
    case off, mouse, keys, controller
}

public struct GyroSettings: Codable, Sendable, Equatable {
    public var source: GyroSource = .off
    /// Radians of yaw per point of horizontal mouse movement.
    public var mouseYawSensitivity: Double = 0.002
    /// Radians of pitch per point of vertical mouse movement.
    public var mousePitchSensitivity: Double = 0.002
    public var invertPitch: Bool = false
    /// Rotation speed while a gyro key is held, in degrees per second.
    public var keyRotationSpeed: Double = 90
    /// Resets the virtual device to level (§14.3), for games that drift or need a level start.
    public var recenterHotkey: String = "option+command+G"

    public init() {}

    enum CodingKeys: String, CodingKey {
        case source, mouseYawSensitivity, mousePitchSensitivity, invertPitch, keyRotationSpeed, recenterHotkey
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GyroSettings()
        source = try c.enumValue(.source, default: d.source)
        mouseYawSensitivity = try c.value(.mouseYawSensitivity, default: d.mouseYawSensitivity)
        mousePitchSensitivity = try c.value(.mousePitchSensitivity, default: d.mousePitchSensitivity)
        invertPitch = try c.value(.invertPitch, default: d.invertPitch)
        keyRotationSpeed = try c.value(.keyRotationSpeed, default: d.keyRotationSpeed)
        recenterHotkey = try c.value(.recenterHotkey, default: d.recenterHotkey)
    }
}

/// How mouse movement drives a virtual stick (§14.1).
public struct StickCurveSettings: Codable, Sendable, Equatable {
    /// Stick deflection per point of mouse movement per frame, before the curve.
    public var sensitivity: Double = 0.08
    /// 1 = linear; above 1 makes small movements finer.
    public var exponent: Double = 1.4
    /// Movements that would give less deflection than this are ignored.
    public var deadzone: Double = 0.02
    /// How quickly the stick returns to centre when the mouse stops, per frame (0–1).
    public var decay: Double = 0.55

    public init() {}

    enum CodingKeys: String, CodingKey {
        case sensitivity, exponent, deadzone, decay
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StickCurveSettings()
        sensitivity = try c.value(.sensitivity, default: d.sensitivity)
        exponent = try c.value(.exponent, default: d.exponent)
        deadzone = try c.value(.deadzone, default: d.deadzone)
        decay = try c.value(.decay, default: d.decay)
    }
}

/// How a real controller's thumbsticks respond (§13.2 accessibility). The defaults change nothing.
public struct ControllerStickSettings: Codable, Sendable, Equatable {
    /// Tilt below this (0–1) counts as centred, for worn sticks that drift.
    public var deadzone: Double = 0
    /// 1 = linear; above 1 makes small tilts finer, below 1 makes them stronger.
    public var exponent: Double = 1

    public init() {}

    enum CodingKeys: String, CodingKey {
        case deadzone, exponent
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ControllerStickSettings()
        deadzone = try c.value(.deadzone, default: d.deadzone)
        exponent = try c.value(.exponent, default: d.exponent)
    }
}

public struct ControlsSettings: Codable, Sendable, Equatable {
    public var playMode: PlayMode = .touch
    /// Live per-game policy; automatic resolves the active map's camera/pointer capability.
    public var interactionStyle: ControlInteractionStyle = .automatic
    /// Discover and track visible HUD controls from any touch map without per-control setup.
    public var automaticHUDAnchoring: Bool = true
    public var cursorKeyBehaviour: CursorKeyBehaviour = .hold
    /// The key that shows the cursor; "option" is the Mac's Alt key.
    public var cursorKey: String = "option"
    public var gyro: GyroSettings = GyroSettings()
    public var mouseToStick: StickCurveSettings = StickCurveSettings()
    /// Key that gives half stick tilt for walking in virtual-controller mode.
    public var walkModifierKey: String = "control"
    /// Trackpad pinch, rotate and two-finger swipe become touch gestures (§13.2).
    public var trackpadGestures: Bool = true
    public var controllerSticks: ControllerStickSettings = ControllerStickSettings()
    /// Camera movement from GCMouse: unaccelerated, and collected until the frame starts. Off by default
    /// until checked on real games.
    public var rawMouse: Bool = false
    /// Keyboard movement starts on the game's next frames instead of after a fixed 40 ms on floating
    /// sticks, so a press registers at once. On by default.
    public var smoothMovement: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case playMode, interactionStyle, automaticHUDAnchoring, cursorKeyBehaviour, cursorKey, gyro, mouseToStick, walkModifierKey, trackpadGestures, controllerSticks, rawMouse, smoothMovement
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ControlsSettings()
        playMode = try c.enumValue(.playMode, default: d.playMode)
        interactionStyle = try c.enumValue(.interactionStyle, default: d.interactionStyle)
        automaticHUDAnchoring = try c.value(.automaticHUDAnchoring, default: d.automaticHUDAnchoring)
        cursorKeyBehaviour = try c.enumValue(.cursorKeyBehaviour, default: d.cursorKeyBehaviour)
        cursorKey = try c.value(.cursorKey, default: d.cursorKey)
        gyro = try c.value(.gyro, default: d.gyro)
        mouseToStick = try c.value(.mouseToStick, default: d.mouseToStick)
        walkModifierKey = try c.value(.walkModifierKey, default: d.walkModifierKey)
        trackpadGestures = try c.value(.trackpadGestures, default: d.trackpadGestures)
        controllerSticks = try c.value(.controllerSticks, default: d.controllerSticks)
        rawMouse = try c.value(.rawMouse, default: d.rawMouse)
        smoothMovement = try c.value(.smoothMovement, default: d.smoothMovement)
    }
}

// MARK: - engine (PLAN.md §1.5 rules 6, 7, 10, 11; §16)

public struct EngineSettings: Codable, Sendable, Equatable {
    /// Keep the Mac output format unless the user explicitly selects another supported format.
    public var audioOutput = AudioOutputSettings()
    /// Per-game crash recovery. Switching it off takes effect on the next launch.
    public var automaticRecovery: Bool = true
    /// Keep the iOS app active when its Mac window loses focus or is minimised. On by default (2026-10-10, user
    /// request): games paused themselves whenever another app came forward. Each game can still switch it off.
    public var keepRunningUnfocused: Bool = true
    /// Module ids switched off for this game from the Modules page.
    public var disabledModules: [String] = []
    /// SHA-256 of each trusted plugin and card, keyed by file name; "absent" binds a missing card.
    public var trustedPluginHashes: [String: String] = [:]
    /// Load plugins the user added without a recorded hash. Off by default.
    public var allowUnverifiedPlugins: Bool = false
    /// Written by the app when it injects the runtime (§1.5 rule 11).
    public var injectedRuntimeVersion: String?
    public var injectedRuntimeProtocol: Int?
    /// Experiment X1: keep the game's own SDK version when converting binaries (§16.4).
    public var keepGameSDKVersion: Bool = false
    /// Let Metal compile the game's shaders on every core it can use (macOS-only
    /// `MTLDevice.shouldMaximizeConcurrentCompilation`): shorter loading screens and fewer
    /// hitches when new effects appear. On by default.
    public var maximizeShaderCompilation: Bool = true
    /// macOS memory pressure reaches the game as the iOS memory warning, so it frees caches like on
    /// an iPhone. On by default.
    public var memoryWarnings: Bool = true
    /// At launch, ask macOS to read the game's big asset files ahead, so the first loads come from memory.
    /// On by default.
    public var readAhead: Bool = true
    /// Give the game's render and per-frame worker threads a QoS class that runs them on the
    /// performance cores first (still every core). Applies to threads started afterwards. On by default.
    public var prioritizeGameThreads: Bool = true
    /// ⌘Q in the game window must be pressed twice within two seconds (a ⌘Tab slip or a held ⌘ quit
    /// games mid-play). Quit from the menu, the Dock or Mulg stays immediate. On by default.
    public var confirmQuitShortcut: Bool = true
    /// A full-screen game stays in the foreground when the player switches to another Space (the
    /// desktop, another app's full screen): UIKit otherwise backgrounds it on every switch, and games
    /// reload, lag or quit. It is throttled while out of view. On by default.
    public var keepForegroundOnOtherSpaces: Bool = true
    /// The game is silent while its window is not the one in use (another app or window in front, hidden,
    /// minimised); sound returns the moment it is. Off by default; also switchable from the in-game menu.
    public var muteWhenUnfocused: Bool = false
    /// Environment variables set in the game process before any module prepares, so Metal, Unity and
    /// other switches read at start-up can be tried per game. `DYLD_` names are ignored.
    public var environment: [String: String] = [:]
    /// Time to allow a cloud-connected game to finish untracked work after backgrounding.
    public var shutdownGraceSeconds: Double = 3
    /// Hard limit for declared iOS background tasks. This cannot confirm a server-side save.
    public var shutdownDeadlineSeconds: Double = 15
    public var shutdownGrace: Double {
        shutdownGraceSeconds.isFinite ? min(max(shutdownGraceSeconds, 1), 30) : 3
    }
    public var shutdownDeadline: Double {
        shutdownDeadlineSeconds.isFinite ? min(max(shutdownDeadlineSeconds, shutdownGrace), 60) : max(15, shutdownGrace)
    }

    public init() {}

    /// Why the runtime would ignore an environment variable; nil when it sets it. The runtime and the
    /// Mulg app both ask here, so what the app saves is what the game sets.
    public enum EnvironmentProblem: Sendable, Equatable { case emptyName, equalsInName, nullCharacter, dyldName }

    public static func environmentProblem(name: String, value: String) -> EnvironmentProblem? {
        if name.isEmpty { return .emptyName }
        if name.contains("=") { return .equalsInName }
        if name.contains("\0") || value.contains("\0") { return .nullCharacter }
        if name.hasPrefix("DYLD_") { return .dyldName }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case disabledModules, trustedPluginHashes, allowUnverifiedPlugins, automaticRecovery, keepRunningUnfocused
        case injectedRuntimeVersion, injectedRuntimeProtocol, keepGameSDKVersion, maximizeShaderCompilation
        case memoryWarnings, readAhead, environment, shutdownGraceSeconds, shutdownDeadlineSeconds, audioOutput
        case prioritizeGameThreads, confirmQuitShortcut, keepForegroundOnOtherSpaces, muteWhenUnfocused
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EngineSettings()
        audioOutput = try c.value(.audioOutput, default: d.audioOutput)
        automaticRecovery = try c.value(.automaticRecovery, default: d.automaticRecovery)
        keepRunningUnfocused = try c.value(.keepRunningUnfocused, default: d.keepRunningUnfocused)
        disabledModules = try c.value(.disabledModules, default: d.disabledModules)
        trustedPluginHashes = try c.value(.trustedPluginHashes, default: d.trustedPluginHashes)
        allowUnverifiedPlugins = try c.value(.allowUnverifiedPlugins, default: d.allowUnverifiedPlugins)
        injectedRuntimeVersion = try c.decodeIfPresent(String.self, forKey: .injectedRuntimeVersion)
        injectedRuntimeProtocol = try c.decodeIfPresent(Int.self, forKey: .injectedRuntimeProtocol)
        keepGameSDKVersion = try c.value(.keepGameSDKVersion, default: d.keepGameSDKVersion)
        maximizeShaderCompilation = try c.value(.maximizeShaderCompilation, default: d.maximizeShaderCompilation)
        memoryWarnings = try c.value(.memoryWarnings, default: d.memoryWarnings)
        readAhead = try c.value(.readAhead, default: d.readAhead)
        prioritizeGameThreads = try c.value(.prioritizeGameThreads, default: d.prioritizeGameThreads)
        confirmQuitShortcut = try c.value(.confirmQuitShortcut, default: d.confirmQuitShortcut)
        keepForegroundOnOtherSpaces = try c.value(.keepForegroundOnOtherSpaces, default: d.keepForegroundOnOtherSpaces)
        muteWhenUnfocused = try c.value(.muteWhenUnfocused, default: d.muteWhenUnfocused)
        environment = try c.value(.environment, default: d.environment)
        shutdownGraceSeconds = try c.value(.shutdownGraceSeconds, default: d.shutdownGraceSeconds)
        shutdownDeadlineSeconds = try c.value(.shutdownDeadlineSeconds, default: d.shutdownDeadlineSeconds)
    }

    public func isModuleEnabled(_ moduleID: String) -> Bool {
        !disabledModules.contains(moduleID)
    }

    public func isModuleEnabled(_ module: ModuleID) -> Bool {
        module.isEssential || isModuleEnabled(module.rawValue)
    }
}

// MARK: - diagnostics (PLAN.md §6.1, §8, §13.4)

public struct DiagnosticsSettings: Codable, Sendable, Equatable {
    /// The small in-game performance overlay for players (§13.4).
    public var performanceOverlay: Bool = false
    public var overlayHotkey: String = "option+command+P"
    /// Measure input-to-present time for every input event (§6.1).
    public var measureInputLatency: Bool = false
    /// Ask the Metal HUD to write its numbers to the system log (§8).
    public var hudLogging: Bool = false
    /// Write a report to the diagnostics folder when the game crashes (§8.3). Nothing is written otherwise.
    public var crashReports: Bool = false // Off for new games: no debugging aids unless asked for.

    /// The debugger (§8.3): `debug.log` in the diagnostics folder, written line by line so it
    /// survives a crash. The categories below count only while this is on. Applied live;
    /// Metal and shader validation only at launch.
    public var debugger: Bool = false
    /// Main-thread hangs with a backtrace; CPU, memory and threads every 5 seconds; memory
    /// warnings, heat, module states; a line per crash. Crash reports are written even when
    /// `crashReports` is off.
    public var debugCPU: Bool = false
    /// Metal API validation (errors are logged, the game goes on), slow frames, refresh-rate,
    /// window and MetalFX changes.
    public var debugGraphics: Bool = false
    /// Metal shader validation: finds shaders that read or write outside their buffers, a
    /// common cause of GPU hangs and garbage on screen. Makes the GPU much slower.
    public var debugShaders: Bool = false
    /// The game's console (stdout, stderr) and every os_log and NSLog message of its process.
    public var debugGameLog: Bool = false

    /// A crash writes a report: asked for directly, or by the debugger's CPU category.
    public var writesCrashReports: Bool { crashReports || (debugger && debugCPU) }

    /// Everything off: what a freshly installed game starts with (no debugging, no measurements,
    /// no crash or freeze reports) whatever older defaults said.
    public static let allOff = DiagnosticsSettings()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case performanceOverlay, overlayHotkey, measureInputLatency, hudLogging, crashReports
        case debugger, debugCPU, debugGraphics, debugShaders, debugGameLog
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DiagnosticsSettings()
        performanceOverlay = try c.value(.performanceOverlay, default: d.performanceOverlay)
        overlayHotkey = try c.value(.overlayHotkey, default: d.overlayHotkey)
        measureInputLatency = try c.value(.measureInputLatency, default: d.measureInputLatency)
        hudLogging = try c.value(.hudLogging, default: d.hudLogging)
        crashReports = try c.value(.crashReports, default: d.crashReports)
        debugger = try c.value(.debugger, default: d.debugger)
        debugCPU = try c.value(.debugCPU, default: d.debugCPU)
        debugGraphics = try c.value(.debugGraphics, default: d.debugGraphics)
        debugShaders = try c.value(.debugShaders, default: d.debugShaders)
        debugGameLog = try c.value(.debugGameLog, default: d.debugGameLog)
    }
}

// MARK: - identity (PLAN.md §3.7)

/// The rest of the identity, so it matches the spoofed model. Names, ranges and counts only, never
/// capabilities: a game is never told about memory or GPU features the Mac doesn't have.
public struct IdentitySettings: Codable, Sendable, Equatable {
    /// Opt-in compatibility preset. Its effective values never overwrite saved preferences;
    /// turning it off restores the user's ordinary identity and CPU reporting choices.
    public var environmentBypass: Bool = false
    /// Model's linked CPU/RAM variant; standard preserves every existing device profile.
    /// M4/M5 iPads support 1/2 TB variants. It takes effect only at the next launch.
    public var deviceConfiguration: MobileDeviceConfiguration = .standard
    /// Cap the memory the game sees at the spoofed device's (12 GB for the iPad Pro M5). A Mac
    /// with less memory keeps reporting its own.
    public var limitMemoryToDevice: Bool = true
    /// `UIDevice.name` and the host name (uname, `kern.hostname`, gethostname) report "iPad", as
    /// a real iPad does to apps, instead of the Mac's name.
    public var genericDeviceName: Bool = true
    /// The game sees a real iPad rather than an iOS app on a Mac: `isiOSAppOnMac` answers NO,
    /// and `UIDevice` model and system name are the device's ("iPad", "iPadOS"). The SoC in the
    /// kernel version, MobileGestalt (HardwarePlatform, ChipID) and IOKit is the device's too
    /// ("t8142"), and MobileGestalt reports the device's class number and panel.
    public var presentAsIPad: Bool = true
    /// Match the selected mobile family's UIKit interface idiom for game callers only.
    /// Separate from SDK-check compatibility; ordinary defaults retain native UI behavior.
    /// The existing consistent-mobile preset includes this without overwriting the preference.
    public var matchMobileInterface: Bool = false
    /// `MTLDevice.name` reports the device's GPU ("Apple M5 GPU") instead of the Mac's chip, which
    /// would contradict the iPad model. Only the name changes, never the GPU's features. The M5
    /// string follows Apple's pattern ("Apple M4 GPU"); check it on a real device.
    public var reportDeviceGPUName: Bool = true
    /// Off by default: report the Mac's real CPU counts so game engines can size their worker
    /// pools for all available cores. macOS schedules the threads; this does not force utilization.
    /// Turn on for compatibility to report the selected iPad's core counts and CPU family instead.
    /// Neither choice restricts scheduling or changes Apple's frameworks' hardware answers.
    public var matchDeviceCPU: Bool = false

    public init() {}

    /// One consistent device for SDKs that reject a mixture of iPad and Mac answers.
    /// It changes reported identity, never hardware features or thread affinity.
    public var effective: IdentitySettings {
        guard environmentBypass else { return self }
        var result = self
        result.limitMemoryToDevice = true
        result.genericDeviceName = true
        result.presentAsIPad = true
        result.matchMobileInterface = true
        result.reportDeviceGPUName = true
        result.matchDeviceCPU = true
        return result
    }

    /// The settings that are off. Each lets the Mac's answer through next to the iPad model, so the
    /// game sees parts of two devices (PLAN.md §3.7). CPU passthrough is the default.
    public var macAnswers: [String] {
        let identity = effective
        return [("identity.limitMemoryToDevice", identity.limitMemoryToDevice), ("identity.genericDeviceName", identity.genericDeviceName),
         ("identity.presentAsIPad", identity.presentAsIPad), ("identity.reportDeviceGPUName", identity.reportDeviceGPUName),
         ("identity.matchDeviceCPU", identity.matchDeviceCPU),
         ("identity.matchMobileInterface", identity.matchMobileInterface)].filter { !$0.1 }.map(\.0)
    }

    enum CodingKeys: String, CodingKey {
        case environmentBypass, deviceConfiguration, limitMemoryToDevice, genericDeviceName, presentAsIPad, matchMobileInterface,
             reportDeviceGPUName, matchDeviceCPU
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IdentitySettings()
        environmentBypass = try c.value(.environmentBypass, default: d.environmentBypass)
        deviceConfiguration = try c.value(.deviceConfiguration, default: d.deviceConfiguration)
        limitMemoryToDevice = try c.value(.limitMemoryToDevice, default: d.limitMemoryToDevice)
        genericDeviceName = try c.value(.genericDeviceName, default: d.genericDeviceName)
        presentAsIPad = try c.value(.presentAsIPad, default: d.presentAsIPad)
        matchMobileInterface = try c.value(.matchMobileInterface, default: d.matchMobileInterface)
        reportDeviceGPUName = try c.value(.reportDeviceGPUName, default: d.reportDeviceGPUName)
        matchDeviceCPU = try c.value(.matchDeviceCPU, default: d.matchDeviceCPU)
    }
}
