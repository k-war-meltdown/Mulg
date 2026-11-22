import Foundation

/// Per-game settings, shared by the Mulg app and the runtime injected into the game.
///
/// Upstream defines this schema twice (`AppSettingsData` in Mulg and in MulgKit)
/// with different defaults, for example `resolution` is 1 in one and 2 in the other.
/// This is the single definition both processes compile (PLAN.md §1.5 rule 3, §12 #2).
///
/// Top-level keys keep upstream's names so files stay readable by upstream Mulg.
/// Everything added by this fork lives under the `mulg` key (`ModuleSettings`), which
/// upstream ignores when reading.
public struct GameSettings: Codable, Sendable, Equatable {
    public var bundleIdentifier: String = ""

    // Controls (upstream keys)
    public var keymapping: Bool = true
    public var sensitivity: Float = 50
    public var noKMOnInput: Bool = true
    public var enableScrollWheel: Bool = true
    public var disableBuiltinMouse: Bool = false
    public var limitMotionUpdateFrequency: Bool = false

    // Identity (upstream keys)
    /// New games start as the iPad Pro 13-inch (M5), Wi-Fi (PLAN.md §3.2). Upstream defaulted to
    /// the M1 iPad13,8; settings files that name a device keep it.
    public var iosDeviceModel: String = "iPad17,3"

    // Display (upstream keys)
    public var disableTimeout: Bool = false
    public var displayRotation: Int = 0
    public var windowWidth: Int = 1920
    public var windowHeight: Int = 1080
    public var customScaler: Double = 2.0
    /// New games use the desktop's full pixel resolution, captured by the host at installation.
    /// Saved choices remain readable and can be changed per game.
    public var resolution: Int = ResolutionMode.display.rawValue
    public var aspectRatio: Int = 1
    public var notch: Bool = false
    public var inverseScreenValues: Bool = false
    public var windowFixMethod: Int = 0
    public var hideTitleBar: Bool = true
    public var floatingWindow: Bool = false
    public var resizableAspectRatioType: Int = 0
    public var resizableAspectRatioWidth: Int = 0
    public var resizableAspectRatioHeight: Int = 0

    // Diagnostics (upstream keys)
    public var metalHUD: Bool = false

    // Integrations (upstream keys)
    public var discordActivity: DiscordActivitySettings = DiscordActivitySettings()
    public var mulgChain: Bool = true
    public var mulgChainDebugging: Bool = false

    // Engine and compatibility (upstream keys)
    public var bypass: Bool = false
    public var injectIntrospection: Bool = false
    public var rootWorkDir: Bool = true
    public var checkMicPermissionSync: Bool = false
    public var blockSleepSpamming: Bool = false
    public var ignoreUnityKeyboardInitializationError: Bool = false

    /// Schema version written by upstream Mulg.
    public var version: String = "3.0.0"

    /// Settings added by this fork, namespaced per module.
    public var mulg: ModuleSettings = ModuleSettings()

    public init() {}

    public init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
    }

    enum CodingKeys: String, CodingKey {
        case bundleIdentifier, keymapping, sensitivity, noKMOnInput, enableScrollWheel
        case disableBuiltinMouse, limitMotionUpdateFrequency, iosDeviceModel
        case disableTimeout, displayRotation, windowWidth, windowHeight, customScaler
        case resolution, aspectRatio, notch, inverseScreenValues, windowFixMethod
        case hideTitleBar, floatingWindow, resizableAspectRatioType
        case resizableAspectRatioWidth, resizableAspectRatioHeight, metalHUD
        case discordActivity, mulgChain, mulgChainDebugging, bypass, injectIntrospection
        case rootWorkDir, checkMicPermissionSync, blockSleepSpamming
        case ignoreUnityKeyboardInitializationError, version, mulg
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GameSettings()
        bundleIdentifier = try c.value(.bundleIdentifier, default: d.bundleIdentifier)
        keymapping = try c.value(.keymapping, default: d.keymapping)
        sensitivity = try c.value(.sensitivity, default: d.sensitivity)
        noKMOnInput = try c.value(.noKMOnInput, default: d.noKMOnInput)
        enableScrollWheel = try c.value(.enableScrollWheel, default: d.enableScrollWheel)
        disableBuiltinMouse = try c.value(.disableBuiltinMouse, default: d.disableBuiltinMouse)
        limitMotionUpdateFrequency = try c.value(.limitMotionUpdateFrequency, default: d.limitMotionUpdateFrequency)
        iosDeviceModel = try c.value(.iosDeviceModel, default: d.iosDeviceModel)
        disableTimeout = try c.value(.disableTimeout, default: d.disableTimeout)
        displayRotation = try c.value(.displayRotation, default: d.displayRotation)
        windowWidth = try c.value(.windowWidth, default: d.windowWidth)
        windowHeight = try c.value(.windowHeight, default: d.windowHeight)
        customScaler = try c.value(.customScaler, default: d.customScaler)
        resolution = try c.value(.resolution, default: d.resolution)
        aspectRatio = try c.value(.aspectRatio, default: d.aspectRatio)
        notch = try c.value(.notch, default: d.notch)
        inverseScreenValues = try c.value(.inverseScreenValues, default: d.inverseScreenValues)
        windowFixMethod = try c.value(.windowFixMethod, default: d.windowFixMethod)
        hideTitleBar = try c.value(.hideTitleBar, default: d.hideTitleBar)
        floatingWindow = try c.value(.floatingWindow, default: d.floatingWindow)
        resizableAspectRatioType = try c.value(.resizableAspectRatioType, default: d.resizableAspectRatioType)
        resizableAspectRatioWidth = try c.value(.resizableAspectRatioWidth, default: d.resizableAspectRatioWidth)
        resizableAspectRatioHeight = try c.value(.resizableAspectRatioHeight, default: d.resizableAspectRatioHeight)
        metalHUD = try c.value(.metalHUD, default: d.metalHUD)
        discordActivity = try c.value(.discordActivity, default: d.discordActivity)
        mulgChain = try c.value(.mulgChain, default: d.mulgChain)
        mulgChainDebugging = try c.value(.mulgChainDebugging, default: d.mulgChainDebugging)
        bypass = try c.value(.bypass, default: d.bypass)
        injectIntrospection = try c.value(.injectIntrospection, default: d.injectIntrospection)
        rootWorkDir = try c.value(.rootWorkDir, default: d.rootWorkDir)
        checkMicPermissionSync = try c.value(.checkMicPermissionSync, default: d.checkMicPermissionSync)
        blockSleepSpamming = try c.value(.blockSleepSpamming, default: d.blockSleepSpamming)
        ignoreUnityKeyboardInitializationError = try c.value(
            .ignoreUnityKeyboardInitializationError, default: d.ignoreUnityKeyboardInitializationError)
        version = try c.value(.version, default: d.version)
        mulg = try c.value(.mulg, default: d.mulg)
    }
}

/// Discord Rich Presence settings (upstream `DiscordActivity`, same keys).
public struct DiscordActivitySettings: Codable, Sendable, Equatable {
    public var enable: Bool = true
    public var applicationID: String = ""
    public var details: String = ""
    public var state: String = ""
    public var image: String = ""

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enable, applicationID, details, state, image
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DiscordActivitySettings()
        enable = try c.value(.enable, default: d.enable)
        applicationID = try c.value(.applicationID, default: d.applicationID)
        details = try c.value(.details, default: d.details)
        state = try c.value(.state, default: d.state)
        image = try c.value(.image, default: d.image)
    }
}
