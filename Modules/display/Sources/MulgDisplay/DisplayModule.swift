import Foundation
import MulgContracts
import MulgDisplayHooks
import MulgEngine
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// The display module inside the game (PLAN.md §4, §6.1, §13.1): the screen the game sees,
/// the refresh rate it is told, how fast it may draw, and throttling while hidden.
@MainActor
public final class DisplayModule: GameModule {
    public let id = ModuleID.display

    public private(set) var displayMaximum = 60
    /// The display varies its refresh rate and the window is full screen (§6.1): a windowed game
    /// is composited at the fixed desktop rate, so only full screen gets exact frame holds.
    public private(set) var variableRefresh = false
    /// Whether the Mac runs on battery; the battery saver cap follows it (§7).
    public private(set) var onBattery = false
    /// Whether macOS Low Power Mode is on; the battery saver treats it like battery power.
    public private(set) var lowPowerMode = false
    /// Whether the Mac is really at a serious or critical thermal state; the thermal guard follows it.
    public private(set) var hot = false
    public private(set) var policy: FrameRatePolicy?
    var unityUnlock = UnityFrameRateUnlock()
    public private(set) var installedHooks: MulgDisplayHook = []
    private var coreOnly = false
    private var warnedAboutProMotion = false
    private var closing = false
    private var observers: [NSObjectProtocol] = []
    /// Keeps macOS from napping or coalescing the game's timers while it is on screen.
    private var activity: NSObjectProtocol?
    private var activeOptions: ProcessInfo.ActivityOptions = []

    public init() {}

    // MARK: Prepare (before the game runs)

    /// Fixed render heights need the game's screen geometry even when its optional display
    /// features are switched off. Without these hooks Metal gets a large drawable while the
    /// renderer still sizes its viewport for the ordinary screen (the top-left-quarter bug).
    public func prepareCore(_ context: ModuleContext) throws -> Bool {
        guard context.settings.targetRenderHeight != nil || !context.settings.mulg.display.retina else { return false }
        coreOnly = true
        try prepare(context)
        return true
    }

    public func prepare(_ context: ModuleContext) throws {
        context.events.subscribe(GameClosing.self) { [weak self] _ in
            guard let self else { return }
            self.closing = true
            self.unityUnlock.task?.cancel()
            self.unityUnlock.task = nil
            self.unityUnlock.target = 0
            // Teardown owns the engine now; do not call Unity to restore a preference.
            self.unityUnlock.gameValue = nil
            self.unityUnlock.lastApplied = nil
        }
        displayMaximum = context.bridge?.displayMaximumRefreshRate ?? 60
        variableRefresh = Self.variableRefresh(context)
        onBattery = context.bridge?.isOnBatteryPower ?? false
        lowPowerMode = mulg_display_real_low_power_mode() != 0
        hot = Self.isHot(mulg_display_real_thermal_state())
        reconfigure(context)

        var attempted: MulgDisplayHook = []
        installedHooks = coreOnly
            ? mulg_display_install_screen_hooks(mulg_display_current_config(), &attempted)
            : mulg_display_install_hooks(&attempted)
        claimHooks(installed: installedHooks, attempted: attempted, context: context)

        applyWindowPreferences(context)
    }

    private struct WindowPreferences: Equatable {
        let hideTitleBar: Bool
        let floating: Bool
        let aspectWidth: Int
        let aspectHeight: Int
        let rememberFrame: Bool

        init(_ settings: GameSettings) {
            let resizable = ScreenGeometry(settings: settings).mode == .resizable
            hideTitleBar = settings.hideTitleBar
            floating = settings.floatingWindow
            // Fixed pixel presets retain their own proportions at every window size.
            // Free and custom resizable proportions retain the user's existing policy.
            aspectWidth = settings.fixedRenderSize?.width ?? (resizable ? settings.resizableAspectRatioWidth : 0)
            aspectHeight = settings.fixedRenderSize?.height ?? (resizable ? settings.resizableAspectRatioHeight : 0)
            rememberFrame = resizable
        }
    }
    private var appliedWindowPreferences: WindowPreferences?

    func applyWindowPreferences(_ context: ModuleContext) {
        guard let bridge = context.bridge else { return }
        let preferences = WindowPreferences(context.settings)
        guard preferences != appliedWindowPreferences else { return }
        appliedWindowPreferences = preferences
        bridge.applyWindowPreferences(hideTitleBar: preferences.hideTitleBar, floating: preferences.floating,
            aspectWidth: preferences.aspectWidth, aspectHeight: preferences.aspectHeight)
        bridge.rememberWindowFrame?(preferences.rememberFrame)
    }

    /// Recomputes the hook configuration from the settings and the current display.
    func reconfigure(_ context: ModuleContext) {
        let settings = context.settings
        // Keep the launch preset and scale. Resizable modes publish live window bounds.
        let geometry = launchGeometry ?? ScreenGeometry(settings: settings)
        launchGeometry = geometry
        mulg_display_set_render_height(Double(settings.targetRenderHeight ?? 0))
        let policy = FrameRatePolicy(displayMaximum: displayMaximum, settings: Self.effectiveDisplay(settings),
                                     onBattery: onBattery || lowPowerMode, hot: hot)
        self.policy = policy

        let headroom = context.bridge?.displayEDRHeadroom ?? 1
        let config = MulgDisplayConfig(
            screenMode: Self.hookMode(geometry.mode),
            width: geometry.width,
            height: geometry.height,
            scale: geometry.scale,
            reportedMaximumFramesPerSecond: coreOnly ? 0 : Int32(policy.reportedMaximum),
            uncapFrameRate: !coreOnly && policy.uncap ? 1 : 0,
            capAtTarget: !coreOnly && policy.capAtTarget ? 1 : 0,
            targetFramesPerSecond: coreOnly ? 0 : Int32(policy.target),
            reportNominalThermalState: !coreOnly && settings.mulg.display.reportNominalThermalState ? 1 : 0,
            hideLowPowerMode: !coreOnly && settings.mulg.display.hideLowPowerMode ? 1 : 0,
            edrHeadroom: !coreOnly && settings.mulg.display.reportHDRHeadroom
                ? (headroom.isFinite ? max(1, headroom) : 1) : 0)
        mulg_display_configure(config)
        updateUnityUnlock(target: coreOnly || !policy.uncap ? 0 : Int32(policy.target), context: context)
    }

    static func hookMode(_ mode: ScreenGeometry.Mode) -> MulgScreenMode {
        switch mode {
        case .off: .off
        case .adaptive: .adaptive
        case .adaptiveInverted: .adaptiveInverted
        case .resizable: .resizable
        }
    }

    /// Every hook this module may install, with its target name and whether it is private API.
    static let hookNames: [(hook: MulgDisplayHook, target: String, isPrivate: Bool)] = [
        (.sceneFrame, "FBSSceneSettingsCore.frame", true),
        (.sceneBounds, "FBSSceneSettings.bounds", true),
        (.displayModeSize, "FBSDisplayMode.size", true),
        (.deviceOrientation, "UIDevice.orientation", false),
        (.screenBounds, "UIScreen.bounds", false),
        (.screenNativeBounds, "UIScreen.nativeBounds", false),
        (.screenScale, "UIScreen.scale", false),
        (.screenNativeScale, "UIScreen.nativeScale", false),
        (.requiresFullScreen, "_UIApplicationInfoParser.requiresFullScreen", true),
        (.maximumFramesPerSecond, "UIScreen.maximumFramesPerSecond", false),
        (.thermalState, "NSProcessInfo.thermalState", false),
        (.lowPowerMode, "NSProcessInfo.isLowPowerModeEnabled", false),
        (.edrHeadroom, "UIScreen.potentialEDRHeadroom", false),
        (.displayLinkRate, "CADisplayLink.setPreferredFrameRateRange:", false),
        (.displayLinkCreation, "CADisplayLink.displayLinkWithTarget:selector:", false),
        (.metalKitViewRate, "MTKView.setPreferredFramesPerSecond:", false)
    ]

    private func claimHooks(installed: MulgDisplayHook, attempted: MulgDisplayHook, context: ModuleContext) {
        for entry in Self.hookNames where attempted.contains(entry.hook) {
            if installed.contains(entry.hook) {
                try? context.hooks.claim(entry.target, owner: id, kind: .swizzle, privateAPI: entry.isPrivate)
            } else {
                context.hooks.recordMissing(entry.target, owner: id, kind: .swizzle, privateAPI: entry.isPrivate)
                context.logger(for: id).error("Could not hook \(entry.target, privacy: .public)")
            }
        }
    }

    // MARK: Activate (after the first scene)

    public func activate(_ context: ModuleContext) {
        if coreOnly {
            removeWindowSizeLimits()
            observeWindowGeometry()
            context.events.subscribe(SettingsChanged.self) { [weak self, weak context] event in
                guard let self, let context, event.old.resolution != event.new.resolution else { return }
                self.reconfigure(context)
            }
            return
        }
        windowVisible = context.bridge?.isWindowVisible ?? true
        context.events.publish(DisplayRefreshRateChanged(maximumRefreshRate: displayMaximum))
        context.events.publish(MacHeatChanged(hot: hot))
        warnIfProMotionUnavailable(context)

        if let bridge = context.bridge {
            bridge.observeDisplayChanges { [weak self, weak context] refreshRate in
                guard let self, let context else { return }
                self.displayChanged(to: refreshRate, context: context)
            }
            bridge.observeWindowVisibility { [weak self, weak context] visible in
                guard let self, let context else { return }
                self.visibilityChanged(visible, context: context)
            }
            bridge.observePowerSource { [weak self, weak context] onBattery in
                guard let self, let context else { return }
                self.powerStateChanged(onBattery: onBattery, lowPowerMode: self.lowPowerMode, context: context)
            }
        }
        // Foundation API, so no bridge call; posted on any thread.
        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self, weak context] _ in
            MainActor.assumeIsolated {
                guard let self, let context else { return }
                self.powerStateChanged(onBattery: self.onBattery, lowPowerMode: mulg_display_real_low_power_mode() != 0,
                                       context: context)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self, weak context] _ in
            MainActor.assumeIsolated {
                guard let self, let context else { return }
                self.thermalStateChanged(hot: Self.isHot(mulg_display_real_thermal_state()), context: context)
            }
        })
        if batterySaverActive(context) {
            context.events.publish(BatterySaverChanged(active: true))
        }
        context.events.subscribe(SettingsChanged.self) { [weak self, weak context] event in
            guard let self, let context else { return }
            self.settingsChanged(from: event.old, context: context)
        }

        if ScreenGeometry(settings: context.settings).mode == .resizable {
            removeWindowSizeLimits()
        }
        observeWindowGeometry()
        registerRotation(context)
        if !windowVisible {
            watchBackgroundWork(visible: false, context: context)
            context.events.publish(WindowVisibilityChanged(visible: false))
        }
        updateActivity(context)
        applyLimits(context)
    }

    #if canImport(UIKit) && !os(watchOS)
    private func observeWindowGeometry() {
        Self.publishWindowGeometry()
        for name in [GameViewport.changed, GameViewport.geometryChanged, UIWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Self.publishWindowGeometry() }
            })
        }
    }

    private static func publishWindowGeometry() {
        let window = GameViewport.shared.window
        mulg_display_set_window_geometry(window?.screen, window?.bounds ?? .zero, Double(window?.screen.nativeScale ?? 0))
    }
    #else
    private func observeWindowGeometry() {}
    #endif

    func displayChanged(to refreshRate: Int, context: ModuleContext) {
        variableRefresh = Self.variableRefresh(context)
        #if canImport(UIKit) && !os(watchOS)
        Self.publishWindowGeometry()
        #endif
        guard refreshRate != displayMaximum else {
            // Another display can have the same Hz but different HDR capabilities.
            reconfigure(context)
            publishFrameLimit(context)
            return
        }
        displayMaximum = refreshRate
        reconfigure(context)
        // Re-apply the rules to every live display link for the new rate, keeping the
        // throttle if the window is hidden.
        applyLimits(context)
        context.events.publish(DisplayRefreshRateChanged(maximumRefreshRate: refreshRate))
        warnedAboutProMotion = false
        warnIfProMotionUnavailable(context)
    }

    static func variableRefresh(_ context: ModuleContext) -> Bool {
        guard let bridge = context.bridge else { return false }
        return (bridge.displayHasVariableRefresh ?? false) && bridge.isFullscreen
    }

    /// Whether the game's battery saver is in effect: it is on for the game, and the Mac runs on
    /// battery or in Low Power Mode (§7).
    func batterySaverActive(_ context: ModuleContext) -> Bool {
        context.settings.mulg.display.batterySaverOnBattery && (onBattery || lowPowerMode)
    }

    /// Battery saver (§7): re-applies the cap to every live display link when the power
    /// source or Low Power Mode changes, and tells the player when it kicks in or ends.
    func powerStateChanged(onBattery: Bool, lowPowerMode: Bool, context: ModuleContext) {
        let wasSaving = batterySaverActive(context)
        let sourceChanged = onBattery != self.onBattery
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
        let saving = batterySaverActive(context)
        if saving != wasSaving {
            reconfigure(context)
            applyLimits(context)
            let cap = context.settings.mulg.display.effectiveFrameRateCap(onBattery: saving, hot: hot)
            let reason = lowPowerMode ? "Low Power Mode" : "Battery saver"
            context.notices.show(Notice(saving ? "\(reason): \(cap) FPS" : "Battery saver off", duration: .seconds(2)))
            context.events.publish(BatterySaverChanged(active: saving))
            updateActivity(context)
        }
        if sourceChanged {
            context.events.publish(PowerSourceChanged(onBattery: onBattery))
        }
    }

    nonisolated static func isHot(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }

    /// Thermal guard (§13.1): caps the game while the Mac is hot, since the game itself is told
    /// the state is nominal. Serious and critical cap; fair and nominal lift the cap.
    func thermalStateChanged(hot: Bool, context: ModuleContext) {
        guard hot != self.hot else { return }
        self.hot = hot
        context.events.publish(MacHeatChanged(hot: hot))
        let display = context.settings.mulg.display
        guard display.thermalGuard else { return }
        reconfigure(context)
        applyLimits(context)
        context.notices.show(Notice(hot ? "Mac is hot: \(display.thermalFrameRateCap) FPS until it cools down" : "Mac cooled down: cap lifted",
                                    style: hot ? .warning : .info, duration: .seconds(3)))
    }

    /// Frame caps, battery saver, thermal guard and the background throttle follow the Mulg app
    /// while the game runs (§7).
    func settingsChanged(from old: GameSettings, context: ModuleContext) {
        let new = context.settings
        // Resolution, custom proportions and window chrome can change live,
        // independently of the display's frame-rate/power policy below.
        applyWindowPreferences(context)
        guard old.mulg.display != new.mulg.display || old.disableTimeout != new.disableTimeout
            || old.mulg.engine.keepRunningUnfocused != new.mulg.engine.keepRunningUnfocused
            || old.resolution != new.resolution else { return }
        let wasSaving = old.mulg.display.batterySaverOnBattery && (onBattery || lowPowerMode)
        reconfigure(context)
        applyLimits(context)
        updateActivity(context)
        let saving = batterySaverActive(context)
        if saving != wasSaving {
            context.events.publish(BatterySaverChanged(active: saving))
        }
    }

    func visibilityChanged(_ visible: Bool, context: ModuleContext) {
        windowVisible = visible
        watchBackgroundWork(visible: visible, context: context)
        updateActivity(context)
        applyLimits(context)
        context.events.publish(WindowVisibilityChanged(visible: visible))
    }

    public private(set) var windowVisible = true
    /// Hidden, but writing to disk fast: the game is downloading or unpacking an update. It then
    /// keeps App Nap away and draws at least `busyFrameRate`, so the download keeps its speed.
    public private(set) var busyInBackground = false
    private var backgroundWatch: Task<Void, Never>?
    private var lastBytesWritten: UInt64 = 0
    private var launchGeometry: ScreenGeometry?
    /// The last `FrameLimitChanged` sent; -1 before the first.
    private var publishedLimit = (framesPerSecond: -1, refreshRate: 0, variableRefresh: false)

    func updateActivity(_ context: ModuleContext) {
        let options = Self.activityOptions(visible: windowVisible, savingBattery: batterySaverActive(context),
                                           keepDisplayAwake: context.settings.disableTimeout,
                                           downloading: busyInBackground,
                                           keepRunning: context.settings.mulg.engine.keepRunningUnfocused)
        guard options != activeOptions else { return }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        let reason = windowVisible ? "Game on screen" : (context.settings.mulg.engine.keepRunningUnfocused
            ? "Game kept running while hidden" : "Game downloading while hidden")
        activity = options.isEmpty ? nil : ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
        activeOptions = options
    }

    /// While the window is visible and the battery saver is off, the game runs as latency-critical
    /// user work: no App Nap, no timer coalescing, no idle clock-down between frames. Hidden or
    /// saving battery, macOS may throttle it again. Hidden but downloading or kept active by
    /// the per-game background-play option, it stays out of App Nap, which
    /// would otherwise slow its network and disk work to a crawl. "Disable display sleep" (`disableTimeout`,
    /// which upstream never applied) keeps the display on while the window is visible.
    static func activityOptions(visible: Bool, savingBattery: Bool, keepDisplayAwake: Bool,
                                downloading: Bool = false, keepRunning: Bool = false) -> ProcessInfo.ActivityOptions {
        guard visible else {
            return keepRunning ? [.userInitiatedAllowingIdleSystemSleep, .latencyCritical]
                : (downloading ? .userInitiatedAllowingIdleSystemSleep : [])
        }
        var options: ProcessInfo.ActivityOptions = savingBattery ? [] : [.userInitiatedAllowingIdleSystemSleep, .latencyCritical]
        if keepDisplayAwake {
            options.insert(.idleDisplaySleepDisabled)
        }
        return options
    }

    /// Re-applies the rules to every live display link (keeping the throttle while hidden) and
    /// tells `graphics` the present limit.
    func applyLimits(_ context: ModuleContext) {
        mulg_display_set_background_throttle(throttleRate(visible: windowVisible, context: context))
        publishFrameLimit(context)
    }

    /// The hard limit on presents: the background throttle while hidden, otherwise the cap from
    /// `display.frameRateCap`, the battery saver and the thermal guard. Display links already
    /// follow it; `graphics` enforces it on every present for engines that draw from their own
    /// loop and never ask a display link (§6.1, §13.1).
    func publishFrameLimit(_ context: ModuleContext) {
        let hidden = Int(throttleRate(visible: windowVisible, context: context))
        let cap = FrameRatePolicy(displayMaximum: displayMaximum, settings: context.settings.mulg.display,
                                  onBattery: onBattery || lowPowerMode, hot: hot).presentCap
        let limit = hidden > 0 ? hidden : cap
        guard limit != publishedLimit.framesPerSecond || displayMaximum != publishedLimit.refreshRate
            || variableRefresh != publishedLimit.variableRefresh else { return }
        publishedLimit = (limit, displayMaximum, variableRefresh)
        context.events.publish(FrameLimitChanged(framesPerSecond: limit, refreshRate: displayMaximum,
                                                 variableRefresh: variableRefresh))
    }

    /// The throttle rate for the window's visibility: 0 (none) while visible or when the
    /// setting is off (§13.1).
    func throttleRate(visible: Bool, context: ModuleContext) -> Int32 {
        let display = context.settings.mulg.display
        guard !visible, display.backgroundThrottle, !context.settings.mulg.engine.keepRunningUnfocused else { return 0 }
        let rate = max(1, display.backgroundFrameRate)
        // Many games unpack one file per frame; the hidden rate would stretch an update to hours.
        let hidden = busyInBackground ? max(rate, Self.busyFrameRate) : rate
        let cap = FrameRatePolicy(displayMaximum: displayMaximum, settings: display,
                                  onBattery: onBattery || lowPowerMode, hot: hot).presentCap
        return Int32(clamping: cap > 0 ? min(hidden, cap) : hidden)
    }

    static let busyFrameRate = 30
    static let busySampleSeconds = 5
    /// 1 MB/s. Saves and logs stay far below it; asset downloads and unpacking stay above.
    static let busyBytesPerSample: UInt64 = 5 << 20

    static func isBusy(bytesWritten: UInt64) -> Bool {
        bytesWritten >= busyBytesPerSample
    }

    static func bytesWritten(since previous: inout UInt64, current: UInt64) -> UInt64? {
        // The native API reports failed reads as zero. Preserve a known baseline
        // so the next successful read cannot count the process's entire history.
        guard current != 0 || previous == 0 else { return nil }
        let delta = current >= previous ? current - previous : 0
        previous = current
        return delta
    }

    /// Samples the game's disk writes every few seconds while the window is hidden.
    /// ponytail: disk writes stand in for downloads; a game that keeps a whole update in memory
    /// until the end is not seen. Count socket bytes if one turns up.
    private func watchBackgroundWork(visible: Bool, context: ModuleContext) {
        backgroundWatch?.cancel()
        backgroundWatch = nil
        busyInBackground = false
        guard !visible else { return }
        lastBytesWritten = mulg_display_bytes_written()
        backgroundWatch = Task { [weak self, weak context] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.busySampleSeconds))
                guard !Task.isCancelled, let self, let context else { return }
                let written = mulg_display_bytes_written()
                guard let bytes = Self.bytesWritten(since: &self.lastBytesWritten, current: written) else { continue }
                let busy = Self.isBusy(bytesWritten: bytes)
                guard busy != self.busyInBackground else { continue }
                self.busyInBackground = busy
                self.updateActivity(context)
                self.applyLimits(context)
            }
        }
    }

    private func warnIfProMotionUnavailable(_ context: ModuleContext) {
        guard policy?.proMotionUnavailable == true, !warnedAboutProMotion else { return }
        warnedAboutProMotion = true
        context.notices.show(Notice(
            "Your display is \(displayMaximum) Hz",
            lines: ["The game sees a 120 Hz iPad. This display can show at most \(displayMaximum) distinct frames per second."],
            style: .warning, duration: .seconds(6)))
    }

    /// Ported from upstream MulgScreen.initialize: a resizable window has no size limits.
    private func removeWindowSizeLimits() {
        #if canImport(UIKit) && !os(watchOS)
        // Activation can follow the first key-window notification. Apply to existing
        // scenes now as well as future key windows; otherwise the first window stays fixed.
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            Self.allowResizing(scene)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { notification in
            // Delivered on the main queue; the object is only read there.
            nonisolated(unsafe) let object = notification.object
            MainActor.assumeIsolated {
                guard let scene = (object as? UIWindow)?.windowScene else { return }
                Self.allowResizing(scene)
            }
        })
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    private static func allowResizing(_ scene: UIWindowScene) {
        scene.sizeRestrictions?.minimumSize = CGSize(width: 240, height: 180)
        // Extreme floating-point limits can overflow Catalyst's AppKit geometry conversion.
        scene.sizeRestrictions?.maximumSize = CGSize(width: 16_384, height: 16_384)
    }
    #endif
}

extension DisplayModule {
    /// The saved rotation, now that the scene is active, and the ⇧⌘1–4 menu items.
    func registerRotation(_ context: ModuleContext) {
        #if canImport(UIKit) && !os(watchOS)
        let saved = DisplayRotation.normalised(context.settings.displayRotation)
        if saved != 0 {
            DisplayRotation.apply(saved)
        }
        for (index, command) in DisplayRotation.menuCommands().enumerated() {
            try? context.menus.register(command, owner: id) { [weak context] in
                guard let context, context.updateSettings({ $0.displayRotation = index }) else { return }
                DisplayRotation.apply(index)
                context.notices.show(Notice("Rotated: \(DisplayRotation.titles[index])", duration: .seconds(2)))
            }
        }
        #endif
    }
}

extension DisplayModule {
    /// "This display" runs at the monitor's own refresh rate: the game sees the real maximum (60, 120,
    /// 144 …) instead of the iPad's 120, and its own 60 FPS limit is lifted up to it.
    nonisolated static func effectiveDisplay(_ settings: GameSettings) -> DisplaySettings {
        var display = settings.mulg.display
        if ResolutionMode(setting: settings.resolution) == .display {
            display.reportProMotion = false
            display.uncapFrameRate = true
        }
        return display
    }
}

// MARK: - Unity frame-rate unlock

extension DisplayModule {
    /// Keeps a Unity IL2CPP game's Application.targetFrameRate at `target` while the frame-rate
    /// unlock is on: games set it again on scene loads and in their settings, so it is checked once
    /// a second. Waits for Unity registration even during a long first launch. When the
    /// unlock goes off, the game's own value comes back.
    func updateUnityUnlock(target: Int32, context: ModuleContext) {
        guard !closing else { return }
        let previous = unityUnlock.target
        unityUnlock.target = target
        // The Unity player hook re-asks the player whenever the target changes.
        if target != previous { unityUnlock.playerRateApplied = false }
        if target <= 60 {
            unityUnlock.task?.cancel()
            unityUnlock.task = nil
            // Gives the player its own request back (the rule passes it through without the uncap).
            if previous > 60 { _ = mulg_display_apply_unity_player_rate() }
            if previous > 60, let original = unityUnlock.gameValue,
               let applied = unityUnlock.lastApplied,
               mulg_display_unity_target_frame_rate() == applied {
                _ = mulg_display_set_unity_target_frame_rate(original)
            }
            unityUnlock.gameValue = nil
            unityUnlock.lastApplied = nil
            unityUnlock.logged = false
            return
        }
        guard unityUnlock.task == nil else { return }
        let logger = context.logger(for: id)
        unityUnlock.task = Task { @MainActor [weak self] in
            // IL2CPP registers its internal calls during startup.
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled, let self, !self.closing {
                // Any Unity player: its frame-rate request reaches the display link raised.
                if !self.unityUnlock.playerRateApplied, mulg_display_apply_unity_player_rate() {
                    self.unityUnlock.playerRateApplied = true
                    logger.notice("Frame-rate unlock: Unity player asks for \(self.unityUnlock.target, privacy: .public) FPS")
                }
                if mulg_display_unity_frame_rate_resolve() {
                    let current = mulg_display_unity_target_frame_rate()
                    // Scene loads/game options may replace the previous request. Keep the
                    // latest game value, while recognizing our own last successful write.
                    if current != self.unityUnlock.lastApplied {
                        self.unityUnlock.gameValue = current
                        self.unityUnlock.lastApplied = nil
                    }
                    let baseline = self.unityUnlock.gameValue ?? current
                    let raised = mulg_display_unity_unlock_target(baseline, self.unityUnlock.target)
                    if raised > 0, raised != current, mulg_display_set_unity_target_frame_rate(raised) {
                        self.unityUnlock.lastApplied = raised
                        if !self.unityUnlock.logged {
                            self.unityUnlock.logged = true
                            logger.notice("Frame-rate unlock: Unity targetFrameRate \(current, privacy: .public) -> \(raised, privacy: .public)")
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// State of the Unity unlock: the target, the game's own value to restore, the polling task.
struct UnityFrameRateUnlock {
    var target: Int32 = 0
    var gameValue: Int32?
    var lastApplied: Int32?
    var task: Task<Void, Never>?
    var logged = false
    var playerRateApplied = false
}
