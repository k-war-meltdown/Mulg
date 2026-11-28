import CoreGraphics
import Foundation
import MulgBridge
import MulgContracts
import MulgControlLayout
import MulgControlsHooks
import MulgEngine
import MulgEngineHooks
#if canImport(GameController)
import GameController
#endif
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// The cursor, window and menu bar, seen through the bridge.
@MainActor
final class BridgeInputEnvironment: InputEnvironment {
    private let bridge: any MacBridge
    private let screen: () -> CGSize
    private let resizable: Bool

    init(bridge: any MacBridge, resizable: Bool, screen: @escaping () -> CGSize) {
        self.bridge = bridge
        self.resizable = resizable
        self.screen = screen
    }

    func cursorPoint() -> CGPoint? {
        #if canImport(UIKit) && !os(watchOS)
        let viewport = GameViewport.shared
        let window = viewport.window?.bounds ?? .zero
        guard let point = CursorMapping.gamePoint(mouse: bridge.mousePoint, window: bridge.windowFrame,
                                                  screen: window.size, fullscreen: bridge.isFullscreen,
                                                  resizable: resizable) else { return nil }
        return viewport.viewPoint(point)
        #else
        CursorMapping.gamePoint(mouse: bridge.mousePoint, window: bridge.windowFrame, screen: screen(),
                                fullscreen: bridge.isFullscreen, resizable: resizable)
        #endif
    }

    func setCursorHidden(_ hidden: Bool) {
        if hidden { bridge.hideCursor() } else { bridge.unhideCursor() }
    }

    func setCursorReleasedByPlayer(_ released: Bool) {
        bridge.setCursorReleasedByPlayer?(released)
    }

    var isFullscreen: Bool { bridge.isFullscreen }
    func setMenuBarVisible(_ visible: Bool) { bridge.setMenuBarVisible(visible) }
}

/// The controls module inside the game (PLAN.md §6.1, §14): keymapping, the hold-Option cursor,
/// the virtual controller, the virtual gyro, real controllers and trackpad gestures.
@MainActor
public final class ControlsModule: GameModule {
    public let id = ModuleID.controls

    public private(set) var router: InputRouter?
    public private(set) var keymap: KeymappingData?
    #if canImport(GameController)
    /// Native input device, available during prepare before the game enumerates controllers.
    public var nativeController: GCController? { virtualController?.controller }
    #endif
    private let dispatcher = ActionDispatcher()
    private var injector: (any TouchInjecting)?
    private var virtualController: VirtualController?
    private var controllerInput: AnyObject?
    /// Whole zoom sweeps for the camera module (Camera reach calibration).
    private var cameraZoom: PinchZoom?
    private var cameraZoomTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var store: KeymapStore?
    /// The keymap file in use; ⌘[ and ⌘] switch between the game's keymaps.
    public private(set) var keymapFile: URL?
    private weak var context: ModuleContext?
    private var environment: BridgeInputEnvironment?
    /// The game screen the actions were placed for.
    private var builtMetrics: ScreenMetrics?
    private var builtGeometryRevision: UInt64 = 0
    private struct ViewportSample: Equatable {
        let metrics: ScreenMetrics
        let revision: UInt64
        var layoutGeometry: ViewportLayoutGeometry {
            ViewportLayoutGeometry(points: CGSize(width: metrics.width, height: metrics.height),
                outputPixels: CGSize(width: metrics.renderWidth, height: metrics.renderHeight), revision: revision)
        }
        var isValid: Bool {
            layoutGeometry.isValid
        }
        var rendererMatchesPoints: Bool {
            layoutGeometry.rendererMatchesPoints
        }
    }
    private var builtViewport: ViewportSample?
    private var pendingViewport: ViewportSample?
    private var viewportTask: Task<Void, Never>?
    private var viewportReflowing = false
    private var viewportCommitCount = 0
    private var proportionChangeCount = 0
    private var viewportMappingReport: [String: Any] {
        guard let sample = builtViewport else { return ["pending": viewportReflowing] }
        return ["pending": viewportReflowing, "commits": viewportCommitCount,
            "proportionChanges": proportionChangeCount,
            "pointWidth": sample.metrics.width, "pointHeight": sample.metrics.height,
            "renderWidth": sample.metrics.renderWidth, "renderHeight": sample.metrics.renderHeight,
            "pointAspect": sample.metrics.width / max(1, sample.metrics.height),
            "renderAspect": sample.metrics.renderAspect,
            "horizontalUnitScale": sample.metrics.horizontalUnitScale,
            "referenceAspect": keymap?.mulgAspectRatio ?? 0,
            "geometryRevision": sample.revision]
    }
    private var liveResizing = false
    private var closing = false
    private var unityKeyboardReady = false
    private var tftVirtualMouse = false
    #if canImport(UIKit) && !os(watchOS)
    private var tftMouseBridge: TFTMouseBridge?
    #endif
    private var nativeCursorCore = false
    private var nativeCursorMode = NativeCursorMode()
    /// WKWebView.didMoveToWindow lists the web views; until then the check walks every view.
    private var webViewsTracked = false
    private var keyboardEditing = false
    private var lastInputReport: ContinuousClock.Instant?
    private var lastDiagnosticNote = ""
    #if canImport(UIKit) && !os(watchOS)
    /// The editor built into controls (the old ⌘K editor). Used while the mapper module is off.
    public let builtInEditor = KeymapEditor()
    /// The editor of the session in progress, so it can't change underneath an open editor.
    private var sessionEditor: (any ControlEditing)?
    /// The editor ⌘K opens: the mapper's when that module runs, otherwise the built-in one.
    public var editor: any ControlEditing { sessionEditor ?? context?.controlEditor ?? builtInEditor }
    private var hudTracker: HUDAnchorTracker?
    private var hudActions: [ControlBindingAddress: any MulgAction] = [:]
    private var hudConfirmationID: UUID?
    private struct MovementTarget {
        let layer: Int
        let index: Int
        let keys: [Int]
        let name: String
    }
    private var movementCalibrationTarget: MovementTarget?
    private var movementCalibrationActive = false
    private var movementCalibrationCenter: CGPoint?
    private var movementCalibrationMetrics: ScreenMetrics?
    private var calibrationMouseRelease = false
    #endif

    public init() {}
    public func requiresBridge(_ settings: GameSettings) -> Bool { settings.keymapping || TFTMouseCompatibility.applies(to: settings.bundleIdentifier) }

    /// Cursor access survives disabled/recovering mapping. This path does not own gameplay
    /// input: a saved touch setting cannot replace the game's input while its mapper is off.
    public func prepareCore(_ context: ModuleContext) throws -> Bool {
        guard context.settings.keymapping || TFTMouseCompatibility.applies(to: context.bundleIdentifier),
              context.bridge != nil else { return false }
        tftVirtualMouse = mulg_controls_prepare_tft_mouse(context.bundleIdentifier)
        nativeCursorCore = true
        mulg_controls_set_pointer_cursor_override(false)
        _ = mulg_controls_install_pointer_cursor_hooks()
        mulg_controls_set_touch_isolation(false)
        return true
    }

    private func activateNativeCursor(_ context: ModuleContext) {
        guard let bridge = context.bridge else { return }
        self.context = context
        // Other native games keep their original capture. TFT's virtual pointer starts
        // visible for its menus; Alt/middle retain their explicit cursor toggles.
        nativeCursorMode = NativeCursorMode(released: tftVirtualMouse)
        if tftVirtualMouse {
            #if canImport(UIKit) && !os(watchOS)
            tftMouseBridge = TFTMouseBridge(bridge: bridge)
            bridge.setupMouseMoved { [weak self] dx, dy in
                self?.tftMouseBridge?.move(dx, dy)
                return false // UIKit hover positions the native game pointer.
            }
            bridge.setupScrollWheel { [weak self] dx, dy in self?.tftMouseBridge?.scroll(dx, dy) ?? false }
            #endif
        } else { mulg_controls_start_native_mouse_relay() }
        applyNativeCursor(bridge)
        writeCorePointerReport()
        context.events.subscribe(GameClosing.self) { [weak self] _ in
            self?.closing = true
            mulg_controls_stop_native_mouse_relay()
            mulg_controls_stop_tft_mouse()
            #if canImport(UIKit) && !os(watchOS)
            self?.tftMouseBridge?.stop()
            self?.tftMouseBridge = nil
            #endif
            self?.lastInputReport = nil
            self?.writeCorePointerReport()
        }
        // Reserve the cursor shortcut in the AppKit stream; gameplay clicks stay native.
        let cursorKeys = InputRouter.keyCodes(forModifierName: context.settings.mulg.controls.cursorKey)
        bridge.setupModifierKeys { [weak self, weak bridge] code, pressed, flags in
            guard let self else { return false }
            guard !self.nativeCursorIsEditing(bridge) else {
                self.nativeCursorMode.focusLost()
                #if canImport(UIKit) && !os(watchOS)
                self.tftMouseBridge?.cancel()
                #endif
                return false
            }
            if self.nativeCursorMode.modifier(code: code, pressed: pressed, cursorKeys: cursorKeys,
                                              commandDown: ModifierSet(appKitFlags: flags).contains(.command)) {
                self.applyNativeCursor(bridge)
            }
            return cursorKeys.contains(code) && !ModifierSet(appKitFlags: flags).contains(.command)
        }
        bridge.setupMouseButtons { [weak self, weak bridge] button, pressed in
            guard let self else { return false }
            #if canImport(UIKit) && !os(watchOS)
            if !pressed, self.tftMouseBridge?.button(button, pressed: false) == true { return true }
            #endif
            guard !self.nativeCursorIsEditing(bridge) else {
                self.nativeCursorMode.focusLost()
                #if canImport(UIKit) && !os(watchOS)
                self.tftMouseBridge?.cancel()
                #endif
                return false
            }
            if self.nativeCursorMode.mouse(button: button, pressed: pressed) {
                self.applyNativeCursor(bridge)
            }
            #if canImport(UIKit) && !os(watchOS)
            if button != 2, self.tftMouseBridge?.button(button, pressed: pressed) == true {
                self.writeCorePointerReport()
                return true
            }
            #endif
            self.writeCorePointerReport()
            return button == 2
        }
        bridge.observeWindowFocus? { [weak self, weak bridge] focused, _ in
            guard let self, !self.closing else { return }
            if !focused {
                self.nativeCursorMode.focusLost()
                #if canImport(UIKit) && !os(watchOS)
                self.tftMouseBridge?.cancel()
                #endif
            }
            else if self.nativeCursorMode.released { self.applyNativeCursor(bridge) }
        }
    }

    private func nativeCursorIsEditing(_ bridge: (any MacBridge)?) -> Bool {
        if closing { return true }
        var editing = bridge?.isTextInputActive == true
        #if canImport(UIKit) && !os(watchOS)
        editing = editing || firstResponderIsEditable()
        #endif
        return editing
    }

    private func applyNativeCursor(_ bridge: (any MacBridge)?) {
        guard let bridge else { return }
        let released = nativeCursorMode.released
        mulg_controls_set_pointer_cursor_override(released)
        // The window border holds the pointer only while the player shows it (Alt or middle click).
        bridge.setCursorReleasedByPlayer?(released)
        #if canImport(UIKit) && !os(watchOS)
        tftMouseBridge?.setCursorReleased(released)
        // The getter changed: let UIKit balance its own capture and cursor visibility.
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                if let root = window.rootViewController { root.setNeedsUpdateOfPrefersPointerLocked() }
            }
        }
        #endif
        // The TFT adapter owns its pointer stream. Releasing it also restores absolute
        // cursor association, even if the game's previous lock left it disconnected.
        if tftVirtualMouse && released { bridge.unhideCursor() }
        // Visibility changes must not warp an absolute game pointer or substitute wrapper
        // capture for the game's own camera policy. UIKit manages native pointer locking.
        // TFT draws its own pointer while released, independent of native hide counts.
        if bridge.setPointerCursorHidden?(tftVirtualMouse || !released) == nil {
            if released { bridge.unhideCursor() } else { bridge.hideCursorUntilMouseMoves() }
        }
    }

    private func writeCorePointerReport() {
        guard let context, lastInputReport.map({ $0.duration(to: .now) >= .seconds(5) }) ?? true else { return }
        lastInputReport = .now
        ReportWriter.shared.writeJSONObject([
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "routingMode": tftVirtualMouse ? "tftVirtualMouse" : "nativePassthrough", "inputMode": "native",
            "configuredInputMode": context.settings.mulg.controls.playMode.rawValue,
            "touchMappingAvailable": false,
            "cursorReleased": nativeCursorMode.released,
            "consumesGameplayInput": tftVirtualMouse, "virtualMouse": mulg_controls_tft_mouse_report(),
            "gameTouch": mulg_controls_game_touch_report(),
            "unavailableContinuedProcessingRequests": mulg_engine_unavailable_continued_tasks(),
            "nativeMouseRelay": mulg_controls_native_mouse_relay_report()
        ], to: context.paths.diagnosticsDirectory(for: context.bundleIdentifier).appendingPathComponent("controls.json"))
    }

    // MARK: Prepare: hooks the game may use before it has a window

    public func prepare(_ context: ModuleContext) throws {
        // TFT uses native keyboard plus a stable virtual mouse, even with mapping enabled.
        if TFTMouseCompatibility.applies(to: context.bundleIdentifier), context.bridge != nil {
            _ = try prepareCore(context)
            return
        }
        let settings = context.settings
        mulg_controls_set_pointer_cursor_override(settings.keymapping)
        let controls = settings.mulg.controls

        let motionHooks = mulg_motion_install_hooks()
        if motionHooks > 0 {
            try? context.hooks.claim("CMMotionManager (gyro and device motion)", owner: id, kind: .swizzle)
        } else {
            context.hooks.recordMissing("CMMotionManager (gyro and device motion)", owner: id, kind: .swizzle)
        }
        mulg_motion_configure(controls.gyro.source != .off)
        registerGyroRecenter(context)

        if mulg_controller_install_hooks() == 2 {
            try? context.hooks.claim("GCController.controllers/current", owner: id, kind: .swizzle)
        }

        // Connect before the game initializes its input devices, rather than waiting for
        // the first window. Games can enumerate the controller during their own startup.
        if settings.keymapping && controls.playMode != .touch {
            let map = KeymapStore(paths: context.paths, bundleIdentifier: context.bundleIdentifier).loadDefault().keymap
            let bindings = map.mulgControllerBindings
                ?? (GenshinDefaults.applies(to: context.bundleIdentifier) ? GenshinDefaults.controllerBindings : [])
            virtualController = VirtualController(bindings: bindings, stickCurve: controls.mouseToStick)
        }

        let compat = mulg_controls_install_compat_hooks(settings.disableBuiltinMouse && mulg_touch_is_available(),
                                                        settings.limitMotionUpdateFrequency)
        if settings.keymapping && controls.playMode == .touch && mulg_touch_is_available() {
            if mulg_controls_install_touch_isolation() > 0 {
                try? context.hooks.claim("GCKeyboard.coalescedKeyboard (touch gameplay isolation)", owner: id, kind: .swizzle)
            }
            mulg_controls_set_touch_isolation(true)
        }
        _ = compat
        imagesChanged(context)
    }

    public func imagesChanged(_ context: ModuleContext) {
        if context.settings.keymapping { _ = mulg_controls_install_pointer_cursor_hooks() }
        if nativeCursorCore { return }
        #if canImport(UIKit) && !os(watchOS)
        if !webViewsTracked, NSClassFromString("WKWebView") != nil {
            webViewsTracked = mulg_controls_track_web_views() == 1
            if webViewsTracked {
                try? context.hooks.claim("WKWebView.didMoveToWindow", owner: id, kind: .swizzle)
                // Web views already on screen before the hook was installed.
                if let webClass = NSClassFromString("WKWebView") {
                    for window in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
                        Self.forEachView(window) { if $0.isKind(of: webClass) { mulg_controls_note_web_view($0) } }
                    }
                }
            }
        }
        #endif
        if !unityKeyboardReady && context.settings.ignoreUnityKeyboardInitializationError {
            unityKeyboardReady = mulg_controls_install_unity_keyboard_fix() == 1
            if unityKeyboardReady {
                try? context.hooks.claim("KeyboardDelegate.Initialize", owner: id, kind: .swizzle, privateAPI: true)
            }
        }
    }

    // MARK: Activate: input handling, once the game has a window

    public func activate(_ context: ModuleContext) {
        if nativeCursorCore { activateNativeCursor(context); return }
        #if canImport(UIKit) && !os(watchOS)
        let settings = context.settings
        let injector = SystemTouchInjector()
        let touchAvailable = mulg_touch_is_available()
        if !touchAvailable {
            context.notices.show(Notice("Touch mapping unavailable",
                lines: ["The system touch interface changed. Native input and virtual gamepad mapping remain available."],
                style: .warning))
            guard settings.mulg.controls.playMode != .touch else { return }
        }
        mulg_touch_set_delivery_handler { [weak context] arrival, delivered in
            MainActor.assumeIsolated {
                guard let context, context.settings.mulg.diagnostics.measureInputLatency
                    || context.settings.mulg.diagnostics.performanceOverlay else { return }
                context.events.publish(InputDelivered(arrival: arrival, injected: delivered))
            }
        }
        self.injector = injector
        if touchAvailable && settings.disableBuiltinMouse {
            simulateMouseDisconnect()
        }
        guard settings.keymapping, let bridge = context.bridge else {
            // Upstream: with keymapping off, MulgKit leaves input alone.
            return
        }

        self.context = context
        let store = KeymapStore(paths: context.paths, bundleIdentifier: context.bundleIdentifier)
        self.store = store
        let loaded = settings.mulg.controls.playMode == .touch ? store.loadTouchDefault() : store.loadDefault()
        keymapFile = loaded.file
        for problem in loaded.problems {
            context.logger(for: id).error("Keymap: \(String(describing: problem), privacy: .public)")
        }
        if loaded.problems.contains(where: { if case .keymapTooNew = $0 { return true }; return false }) {
            context.notices.show(Notice("Keymap format too new",
                                        lines: ["This keymap was made by a newer version and was not loaded, to protect it."],
                                        style: .warning, duration: .seconds(6)))
        }
        let conflicts = KeymapConflicts.find(in: loaded.keymap)
        if !conflicts.isEmpty {
            // One of two bindings on the same key never works; say which (§14.5).
            context.notices.show(Notice("Keymap: keys used twice", lines: conflicts.prefix(3).map(\.description),
                                        style: .warning, duration: .seconds(6)))
        }
        var keymap = loaded.keymap
        let isGenshin = GenshinDefaults.applies(to: context.bundleIdentifier)
        if isGenshin { keymap = GenshinDefaults.correctedTouchInputs(keymap) }
        if StarRailDefaults.applies(to: context.bundleIdentifier) { keymap = StarRailDefaults.adaptiveTouchLayout(keymap) }
        if isGenshin && keymap.mulgControllerBindings == nil {
            keymap.mulgControllerBindings = GenshinDefaults.controllerBindings
        }
        self.keymap = keymap
        applyKeymapWindowShape(keymap, context: context)

        let resolution = ResolutionMode(setting: settings.resolution)
        let resizable = !resolution.isAdaptive && resolution != .off
        let environment = BridgeInputEnvironment(bridge: bridge, resizable: resizable) { [weak injector] in
            injector?.screenBounds.size ?? .zero
        }
        self.environment = environment
        let fakeMouse = FakeMouseAction(injector: injector)
        var routingSettings = settings
        if !touchAvailable { routingSettings.mulg.controls.playMode = .virtualController }
        let router = InputRouter(settings: routingSettings, dispatcher: dispatcher, hotkeys: context.hotkeys,
                                 events: context.events, environment: environment, fakeMouse: fakeMouse,
                                 menuKeys: AdaptiveControlPlan.resolve(keymap, bundleIdentifier: context.bundleIdentifier,
                                     nativeController: routingSettings.mulg.controls.playMode == .virtualController,
                                     hybridController: routingSettings.mulg.controls.playMode == .hybrid,
                                     mouseGyro: routingSettings.mulg.controls.gyro.source == .mouse,
                                     interactionStyle: routingSettings.mulg.controls.interactionStyle).menuKeys)
        self.router = router
        router.touchMappingAvailable = touchAvailable
        #if canImport(UIKit) && !os(watchOS)
        context.events.subscribe(MemoryPressure.self) { [weak self] _ in self?.hudTracker?.pauseCaptures() }
        #endif
        // The 5-second snapshot may be old; closing writes the last one (flushed before exit).
        context.events.subscribe(GameClosing.self) { [weak self, weak router] _ in
            guard let self, let router else { return }
            self.closing = true
            self.cameraZoomTask?.cancel()
            self.cameraZoomTask = nil
            self.cameraZoom?.cancel()
            self.viewportTask?.cancel()
            self.viewportTask = nil
            self.pendingViewport = nil
            #if canImport(UIKit) && !os(watchOS)
            self.cancelMovementCalibration()
            self.cancelHUDConfirmation()
            self.hudTracker?.suspend()
            #endif
            router.stop()
            #if canImport(GameController)
            (self.controllerInput as? ControllerInput)?.focusLost()
            #endif
            self.injector?.setSuspended(true)
            mulg_engine_set_frame_start_handler(nil)
            mulg_motion_configure(false)
            self.lastInputReport = nil
            self.writeInputReport(router)
        }
        context.events.subscribe(SettingsChanged.self) { [weak self, weak router] change in
            guard self?.closing != true else { return }
            // Other modules' settings (frame limit, MetalFX…) must not re-run the control plan,
            // which re-applies the input mode and cursor capture mid-game.
            let old = change.old, new = change.new
            guard old.mulg.controls != new.mulg.controls || old.sensitivity != new.sensitivity else {
                router?.updateMeasurementSettings(new)
                return
            }
            router?.updateTuning(new)
            self?.hudTracker?.updateAutomatic(change.new.mulg.controls.automaticHUDAnchoring)
            #if canImport(GameController)
            (self?.controllerInput as? ControllerInput)?.updateStickSettings(change.new.mulg.controls.controllerSticks)
            #endif
        }
        hudTracker = HUDAnchorTracker(bridge: bridge, snapshot: { [weak injector] in
            guard let metrics = injector?.screenMetrics else { return nil }
            return HUDAnchorTracker.currentSnapshot(metrics: metrics)
        }, canTrack: { [weak self, weak router] in
            guard let self, let router else { return false }
            return !self.liveResizing && !self.viewportReflowing && !self.editor.isOpen
                && self.hudConfirmationID == nil && !self.movementCalibrationActive
                && router.controllerTouchMappingActive
        }, activeLayer: { [weak self] in
            self?.dispatcher.activeLayer ?? 0
        }, beginCapture: { [weak context] in
            context?.notices.beginVisualCapture() ?? UUID()
        }, endCapture: { [weak context] token in
            context?.notices.endVisualCapture(token)
        }, notice: { [weak context] title, line, warning in
            context?.notices.show(Notice(title, lines: [line], style: warning ? .warning : .info, duration: .seconds(6)))
        })
        hudTracker?.updateAutomatic(settings.mulg.controls.automaticHUDAnchoring)
        buildActions(keymap: keymap, injector: injector, environment: environment, router: router)
        router.keymapRebuilt(self.keymap ?? keymap)

        if settings.mulg.controls.playMode != .touch {
            let bindings = keymap.mulgControllerBindings ?? []
            let controller = virtualController ?? VirtualController(bindings: bindings,
                                               stickCurve: settings.mulg.controls.mouseToStick)
            controller.rebind(bindings)
            virtualController = controller
            router.virtualController = controller
        }
        #if canImport(GameController)
        let realControllers = ControllerInput(dispatcher: dispatcher, virtualController: virtualController?.controller,
                                              sticks: settings.mulg.controls.controllerSticks,
                                              isVirtualController: { [weak virtualController] in virtualController?.owns($0) == true })
        router.onLayerChanged = { [weak self, weak realControllers] _ in
            realControllers?.mappingContextChanged()
            self?.hudTracker?.recheck()
        }
        router.onMappedModeChanged = { [weak self, weak realControllers, weak router] in
            realControllers?.mappingContextChanged()
            if router?.controllerTouchMappingActive == true { self?.hudTracker?.recheck() }
            else { self?.hudTracker?.suspend() }
        }
        realControllers.acceptsTouchMapping = { [weak router] in router?.controllerTouchMappingActive ?? false }
        realControllers.acceptsCameraMapping = { [weak router] in router?.mode == .camera }
        realControllers.onButton = { [weak router] name, pressed in router?.controllerButton(name, pressed: pressed) ?? false }
        if settings.mulg.controls.gyro.source == .controller {
            realControllers.onMotion = { [weak router] x, y, z in router?.controllerMotion(x: x, y: y, z: z) }
        }
        controllerInput = realControllers
        #endif
        if touchAvailable {
            router.gestures = TrackpadGestures(injector: injector) { [weak injector] in
                injector?.screenMetrics ?? ScreenMetrics(bounds: .zero)
            }
            // Camera reach calibration zooms the camera itself (CameraZoomRequested).
            let pinch = PinchZoom(injector: injector) { [weak injector] in
                injector?.screenMetrics ?? ScreenMetrics(bounds: .zero)
            }
            cameraZoom = pinch
            context.events.subscribe(CameraZoomRequested.self) { [weak self, weak pinch] request in
                guard let self, !self.closing else { return }
                self.cameraZoomTask?.cancel()
                self.cameraZoomTask = Task { @MainActor in
                    guard !Task.isCancelled else { return }
                    await pinch?.sweep(outward: request.outward, gestures: request.gestures)
                }
            }
            context.events.subscribe(CameraZoomCancelled.self) { [weak self, weak pinch] _ in
                self?.cameraZoomTask?.cancel()
                self?.cameraZoomTask = nil
                pinch?.cancel()
            }
        }

        connect(bridge: bridge, router: router)
        mulg_engine_set_frame_start_handler { [weak self, weak router] in
            MainActor.assumeIsolated {
                guard self?.closing != true else { return }
                FrameTicker.shared.tick()
                self?.refreshControlGeometry()
                #if canImport(GameController)
                // Before frameStarts, whose flush hands this step's touches to the game.
                (self?.controllerInput as? ControllerInput)?.frameStarted()
                #endif
                router?.frameStarts()
                self?.hudTracker?.applyPending()
            }
        }
        if settings.mulg.controls.rawMouse {
            startRawMouse(router: router)
        }
        observeTextInput(router: router)
        observeFocusLoss(router: router)
        observeWindowResize(keymap: keymap, injector: injector, environment: environment, router: router)
        router.start()
        virtualController?.connectNativeDevice()
        observeNativeInterface(bridge: bridge, router: router)
        registerMenuCommands(context, bridge: bridge)

        if isGenshin && settings.mulg.controls.playMode != .touch {
            context.notices.show(Notice("PC controls: select Controller in Genshin",
                lines: ["Settings → Controls → Control Type → Controller. Use the default controller bindings.",
                        "WASD moves; mouse looks; click/hold attacks; E/Q casts; 1–4 switches characters; M opens the map.",
                        "If Controller is absent, select Keyboard & mouse (touchscreen) in Mulg instead."],
                duration: .seconds(12)))
        }
        if isGenshin && settings.mulg.controls.playMode == .touch {
            context.notices.show(Notice("Keyboard & mouse: touchscreen controls",
                lines: ["Leave Genshin's Control Type set to Touchscreen.",
                        "Tap Option or click the mouse wheel for the cursor; again to return to the camera."],
                duration: .seconds(6)))
        }
        if router.mode == .camera {
            context.notices.show(Notice("Tap ⌥ Option or click the mouse wheel for the cursor", duration: .seconds(4)))
        }
        #endif
    }

    /// Native controller input needs no HUD shape. Touch presets can explicitly request
    /// their calibrated aspect; resizing keeps that shape instead of guessing a new HUD.
    private func applyKeymapWindowShape(_ keymap: KeymappingData, context: ModuleContext) {
        let settings = context.settings
        var width = settings.resizableAspectRatioWidth, height = settings.resizableAspectRatioHeight
        if settings.mulg.controls.playMode == .touch, keymap.mulgLockAspectRatio == true,
           let aspect = keymap.mulgAspectRatio, aspect.isFinite, aspect >= 1, aspect <= 4 {
            width = Int((aspect * 900).rounded()); height = 900
        }
        context.bridge?.applyWindowPreferences(hideTitleBar: settings.hideTitleBar,
            floating: settings.floatingWindow, aspectWidth: width, aspectHeight: height)
    }

    /// Legacy maps acquire a durable reference shape once, including after relaunch.
    /// Calibrated maps retain their original reference; unreadable maps are never repaired here.
    private func rememberReferenceCanvas(_ original: KeymappingData, metrics: ScreenMetrics) -> KeymappingData {
        guard original.hasTouchControls,
              metrics.width.isFinite, metrics.height.isFinite, metrics.width > 0, metrics.height > 0 else { return original }
        var map = original
        map.mulgAspectRatio = map.mulgAspectRatio ?? metrics.renderAspect
        map = map.withAdaptiveLayouts()
        guard map != original else { return original }
        self.keymap = map
        if let store, let file = keymapFile, let problem = store.write(map, to: file) {
            context?.logger(for: id).error("Reference canvas not saved: \(String(describing: problem), privacy: .public)")
        }
        return map
    }

    // MARK: Building actions from the keymap

    private func buildActions(keymap: KeymappingData, injector: any TouchInjecting,
                             environment: any InputEnvironment, router: InputRouter) {
        (controllerInput as? ControllerInput)?.keymapRebuilt()
        dispatcher.clear()
        #if canImport(UIKit) && !os(watchOS)
        hudActions.removeAll()
        #endif
        guard keymap.isSupportedVersion, mulg_touch_is_available() else { return }
        let metrics = injector.screenMetrics
        builtMetrics = metrics
        #if canImport(UIKit) && !os(watchOS)
        builtGeometryRevision = GameViewport.shared.geometryRevision
        builtViewport = ViewportSample(metrics: metrics, revision: builtGeometryRevision)
        #endif
        let keymap = rememberReferenceCanvas(keymap, metrics: metrics)
        // Keep the untouched reference map. Every action resolves it directly against
        // the latest viewport; resizing never compounds a previously fitted transform.
        let live: () -> ScreenMetrics = { [weak injector] in injector?.screenMetrics ?? ScreenMetrics(bounds: .zero) }

        dispatcher.add(router.fakeMouse)
        addElements(buttons: keymap.buttonModels, draggables: keymap.draggableButtonModels, areas: keymap.mouseAreaModel,
                    joysticks: keymap.joystickModel, metrics: metrics, live: live, injector: injector,
                    environment: environment, router: router, referenceAspect: keymap.mulgAspectRatio, layerIndex: 0)
        // Layers (§14.5): their actions register under the layer, used while its key is held.
        for (index, layer) in (keymap.mulgLayers ?? []).enumerated() where layer.hasHoldKey {
            dispatcher.beginLayer(index + 1, holdKey: layer.holdKeyName)
            addElements(buttons: layer.buttonModels, draggables: layer.draggableButtonModels, areas: layer.mouseAreaModel,
                        joysticks: layer.joystickModel, metrics: metrics, live: live, injector: injector,
                        environment: environment, router: router, referenceAspect: keymap.mulgAspectRatio, layerIndex: index + 1)
            dispatcher.endLayer()
        }
        dispatcher.setLiveResizing(liveResizing || viewportReflowing)
        dispatcher.add(ScrollDragAction(injector: injector, dispatcher: dispatcher, liveMetrics: live, referenceAspect: keymap.mulgAspectRatio) { [weak environment] in
            environment?.cursorPoint()
        })
        #if canImport(UIKit) && !os(watchOS)
        let references = keymapFile.flatMap { file in
            store.map { HUDReferenceStore(keymapFolder: $0.folder, keymapName: file.lastPathComponent) }
        }
        hudTracker?.configure(map: keymap, actions: hudActions, referenceStore: references)
        #endif
    }

    private func addElements(buttons: [ButtonElement], draggables: [ButtonElement], areas: [MouseAreaElement],
                             joysticks: [JoystickElement], metrics: ScreenMetrics, live: @escaping () -> ScreenMetrics,
                             injector: any TouchInjecting, environment: any InputEnvironment, router: InputRouter,
                             referenceAspect: Double?, layerIndex: Int) {
        for (index, element) in buttons.enumerated() {
            let action = ButtonAction(element: element, metrics: metrics, injector: injector, dispatcher: dispatcher, referenceAspect: referenceAspect)
            dispatcher.add(action)
            registerHUDAction(action, kind: .button, index: index, layer: layerIndex)
        }
        for (index, element) in draggables.enumerated() {
            let action = DraggableButtonAction(element: element, metrics: metrics, injector: injector, dispatcher: dispatcher, referenceAspect: referenceAspect)
            dispatcher.add(action)
            registerHUDAction(action, kind: .draggable, index: index, layer: layerIndex)
        }
        for element in areas {
            dispatcher.add(CameraAction(element: element, metrics: metrics, injector: injector,
                                        dispatcher: dispatcher, liveMetrics: live, referenceAspect: referenceAspect))
        }
        for (index, element) in joysticks.enumerated() {
            if element.isAnalog {
                let action = AnalogJoystickAction(element: element, metrics: metrics, injector: injector, dispatcher: dispatcher, referenceAspect: referenceAspect)
                dispatcher.add(action)
                registerHUDAction(action, kind: .analogJoystick, index: index, layer: layerIndex)
            } else {
                let smooth = context?.settings.mulg.controls.smoothMovement ?? true
                let action = KeyJoystickAction(element: element, metrics: metrics, injector: injector, dispatcher: dispatcher,
                                               referenceAspect: referenceAspect,
                                               framePacedActivation: smooth,
                                               glide: element.effectiveMode == .FLOATING)
                dispatcher.add(action)
                registerHUDAction(action, kind: .digitalJoystick, index: index, layer: layerIndex)
            }
        }
    }

    private func registerHUDAction(_ action: any MulgAction, kind: ControlBindingKind, index: Int, layer: Int) {
        #if canImport(UIKit) && !os(watchOS)
        hudActions[ControlBindingAddress(layer: layer, kind: kind, index: index)] = action
        #endif
    }

    // MARK: Wiring

    private func connect(bridge: any MacBridge, router: InputRouter) {
        bridge.observeWindowFocus? { [weak self, weak router] focused, onScreen in
            guard self?.closing != true else { return }
            if focused && onScreen {
                router?.focusGained()
                #if canImport(UIKit) && !os(watchOS)
                self?.hudTracker?.recheck()
                #endif
                #if canImport(GameController)
                (self?.controllerInput as? ControllerInput)?.focusGained()
                #endif
            } else {
                #if canImport(UIKit) && !os(watchOS)
                self?.cancelMovementCalibration()
                self?.cancelHUDConfirmation()
                self?.hudTracker?.suspend()
                #endif
                router?.focusLost()
                #if canImport(GameController)
                (self?.controllerInput as? ControllerInput)?.focusLost()
                #endif
            }
        }
        bridge.setupKeyboard { [weak self, weak router, weak bridge] code, pressed, isRepeat, flags in
            #if canImport(UIKit) && !os(watchOS)
            if self?.movementCalibrationActive == true {
                if code == 0x35 && pressed { self?.cancelMovementCalibration() }
                return true
            }
            #endif
            self?.refreshTextInput(bridge: bridge, router: router)
            return router?.key(code: code, pressed: pressed, isRepeat: isRepeat, flags: flags) ?? false
        }
        bridge.setupModifierKeys { [weak self, weak router, weak bridge] code, pressed, flags in
            #if canImport(UIKit) && !os(watchOS)
            if self?.movementCalibrationActive == true { return true }
            #endif
            self?.refreshTextInput(bridge: bridge, router: router)
            return router?.modifier(code: code, pressed: pressed, flags: flags) ?? false
        }
        bridge.setupMouseMoved { [weak self, weak router, weak bridge] dx, dy in
            #if canImport(UIKit) && !os(watchOS)
            if self?.movementCalibrationActive == true { return true }
            #endif
            self?.refreshTextInput(bridge: bridge, router: router)
            return router?.mouseMoved(dx: dx, dy: dy) ?? false
        }
        bridge.setupMouseButtons { [weak self, weak router, weak bridge] button, pressed in
            #if canImport(UIKit) && !os(watchOS)
            if self?.handleMovementCalibrationClick(button: button, pressed: pressed) == true { return true }
            #endif
            self?.refreshTextInput(bridge: bridge, router: router)
            return router?.mouseButton(button, pressed: pressed) ?? false
        }
        bridge.setupScrollWheel { [weak router] dx, dy in
            router?.scroll(dx: dx, dy: dy) ?? false
        }
        bridge.setupMagnify { [weak router] amount, phase in
            router?.magnify(amount, phase: phase) ?? false
        }
        bridge.setupRotate { [weak router] degrees, phase in
            router?.rotate(degrees, phase: phase) ?? false
        }
    }

    #if canImport(UIKit) && !os(watchOS)
    /// A non-editable web page still owns native pointer gestures (sliders, buttons, scrolling).
    /// The same test as `hasVisibleWebInterface`, from one web view up to its window: every view on
    /// the way is shown, not transparent, not empty and on screen, and the web view takes input.
    private func isVisibleWebInterface(_ webView: UIView, in window: UIWindow) -> Bool {
        guard webView.isUserInteractionEnabled else { return false }
        var view: UIView? = webView
        while let current = view {
            guard !current.isHidden, current.alpha > 0.01, !current.bounds.isEmpty,
                  current.convert(current.bounds, to: window).intersects(window.bounds) else { return false }
            if current === window { return true }
            view = current.superview
        }
        return false
    }

    private static func forEachView(_ view: UIView, _ body: (UIView) -> Void) {
        body(view)
        for subview in view.subviews { forEachView(subview, body) }
    }

    /// Hidden/offscreen preloaded pages must not suspend the gameplay keymap.
    private func hasVisibleWebInterface(_ view: UIView, in window: UIWindow, webClass: AnyClass) -> Bool {
        guard !view.isHidden, view.alpha > 0.01, !view.bounds.isEmpty,
              view.convert(view.bounds, to: window).intersects(window.bounds) else { return false }
        if view.isKind(of: webClass), view.isUserInteractionEnabled { return true }
        return view.subviews.contains { hasVisibleWebInterface($0, in: window, webClass: webClass) }
    }

    /// Whether the key window's first responder takes text. Asked four times a second, so UIKit
    /// names the responder (a nil-targeted action) instead of every view being walked.
    private func firstResponderIsEditable() -> Bool {
        guard let responder = UIResponder.mulgCurrentFirstResponder, !(responder is UIApplication) else { return false }
        if let field = responder as? UITextField { return field.isEnabled }
        if let text = responder as? UITextView { return text.isEditable }
        if mulg_controls_responder_is_editable(responder) { return true }
        if let input = responder as? any UITextInput, input.markedTextRange != nil { return true }
        return false
    }
    #endif

    private func refreshTextInput(bridge: (any MacBridge)?, router: InputRouter?) {
        guard !closing else { return }
        #if canImport(UIKit) && !os(watchOS)
        refreshControlGeometry()
        #endif
        guard let router else { return }
        var editing = keyboardEditing || bridge?.isTextInputActive == true
        #if canImport(UIKit) && !os(watchOS)
        var windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        if windows.isEmpty, let legacy = GameViewport.shared.window { windows = [legacy] }
        editing = editing || firstResponderIsEditable()
        let nativeInterface: Bool
        if webViewsTracked {
            nativeInterface = mulg_controls_web_views().contains { view in
                guard let view = view as? UIView, let window = view.window, windows.contains(window),
                      window.windowScene?.activationState != .background else { return false }
                return isVisibleWebInterface(view, in: window)
            }
        } else {
            let webClass: AnyClass? = NSClassFromString("WKWebView")
            nativeInterface = windows.contains { window in
                guard let webClass, window.windowScene?.activationState != .background else { return false }
                return hasVisibleWebInterface(window, in: window, webClass: webClass)
            }
        }
        router.setNativeInterfaceActive(nativeInterface)
        #endif
        if editing { router.textInputBegan() } else { router.textInputEnded() }
        mulg_controls_set_touch_isolation(context?.settings.mulg.controls.playMode == .touch
            && (router.mode == .camera || router.mode == .cursor)
            && !editing && !router.nativeInterfaceActive)
        (controllerInput as? ControllerInput)?.setTextInputActive(editing || router.nativeInterfaceActive)
    }

    /// Notice an interface opening even when the captured mouse has not moved yet. Also
    /// restore gameplay after dismissal without requiring an extra key or mouse event.
    private func observeNativeInterface(bridge: any MacBridge, router: InputRouter) {
        guard !closing else { return }
        refreshTextInput(bridge: bridge, router: router)
        #if canImport(UIKit) && !os(watchOS)
        writeInputReport(router)
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak bridge, weak router] in
            MainActor.assumeIsolated {
                guard let self, let bridge, let router else { return }
                self.observeNativeInterface(bridge: bridge, router: router)
            }
        }
    }

    #if canImport(UIKit) && !os(watchOS)
    /// Key releases stop reaching the game once its window loses focus, so lift every touch then,
    /// and end a hold-mode cursor whose key was let go elsewhere once it is back.
    private func observeFocusLoss(router: InputRouter) {
        observers.append(NotificationCenter.default.addObserver(forName: UIScene.willDeactivateNotification, object: nil,
                                                                queue: .main) { [weak self, weak router] note in
            let scene = note.object as? UIWindowScene
            MainActor.assumeIsolated {
                if let scene, let current = GameViewport.shared.window?.windowScene, scene !== current { return }
                self?.cancelMovementCalibration()
                (self?.controllerInput as? ControllerInput)?.focusLost()
                router?.focusLost()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil,
                                                                queue: .main) { [weak self, weak router] note in
            let scene = note.object as? UIWindowScene
            MainActor.assumeIsolated {
                guard self?.closing != true else { return }
                if let scene, let current = GameViewport.shared.window?.windowScene,
                   scene !== current && !scene.windows.contains(where: \.isKeyWindow) { return }
                router?.focusGained()
                (self?.controllerInput as? ControllerInput)?.focusGained()
            }
        })
    }

    private func observeTextInput(router: InputRouter) {
        let began: [Notification.Name] = [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification,
                                         UIResponder.keyboardWillShowNotification]
        let ended: [Notification.Name] = [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification,
                                         UIResponder.keyboardWillHideNotification]
        for name in began {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak router] _ in
                MainActor.assumeIsolated {
                    self?.keyboardEditing = true
                    self?.refreshTextInput(bridge: self?.context?.bridge, router: router)
                }
            })
        }
        for name in ended {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak router] _ in
                MainActor.assumeIsolated {
                    self?.keyboardEditing = false
                    self?.refreshTextInput(bridge: self?.context?.bridge, router: router)
                }
            })
        }
    }

    /// Small, throttled evidence for the actual game session. No key names, text, credentials
    /// or game data are recorded. This distinguishes routing/connection from HUD geometry.
    private func writeInputReport(_ router: InputRouter) {
        // A snapshot for exported bug reports; nothing reads it live.
        guard let context, lastInputReport.map({ $0.duration(to: .now) >= .seconds(5) }) ?? true else { return }
        lastInputReport = .now
        let bounds = injector?.screenBounds ?? .zero
        var report: [String: Any] = ["timestamp": Date().timeIntervalSince1970,
            "profile": keymapFile?.deletingPathExtension().lastPathComponent ?? "",
            "inputMode": context.settings.mulg.controls.playMode.rawValue,
            "routingMode": router.mode.rawValue, "nativeInterfaceActive": router.nativeInterfaceActive,
            "viewportWidth": bounds.width, "viewportHeight": bounds.height,
            "keyPresses": router.gameplayKeyPresses, "mousePresses": router.gameplayMousePresses,
            "gameControllerReads": mulg_controller_game_read_count(),
            "touchJoysticks": dispatcher.actions.compactMap(\.inputDiagnostics).filter { $0["kind"] == 2 },
            "touchDelivery": injector?.deliveryDiagnostics ?? [:],
            "inputOwnership": ["held": dispatcher.heldInputCount, "repeatedDowns": dispatcher.repeatedPresses,
                "orphanUps": dispatcher.orphanReleases, "movementTransfers": dispatcher.movementTransfers,
                "suppressedMovement": dispatcher.suppressedMovementCount],
            "viewportMapping": viewportMappingReport,
            "mappedControls": dispatcher.actions.compactMap(\.inputDiagnostics)]
        #if canImport(UIKit) && !os(watchOS)
        report["hudAnchors"] = hudTracker?.report ?? [:]
        #endif
        if let plan = router.controlPlan {
            report["adaptiveControlPlan"] = ["game": plan.game, "context": plan.context,
                "family": plan.family, "capturesMouse": plan.capturesMouse,
                "hasRelativeCamera": plan.hasRelativeCamera, "movementSticks": plan.movementSticks,
                "calibratedSticks": plan.calibratedSticks, "projectedControls": plan.projectedControls,
                "measuredControls": plan.measuredControls, "learnedControls": plan.learnedControls, "effectiveBindings": plan.effectiveBindings,
                "shadowedBindings": plan.shadowedBindings, "bindingConflicts": plan.bindingConflicts] as [String: Any]
        }
        #if canImport(GameController)
        if let native = nativeController {
            report["nativeControllerConnected"] = GCController.controllers().contains { $0 === native }
            report["controllerCategory"] = native.productCategory
            report["controllerVendor"] = native.vendorName ?? ""
            report["controllerIsSnapshot"] = native.isSnapshot
            report["nativeDeviceConnectionError"] = virtualController?.deviceConnectionError ?? ""
        }
        #endif
        // A few lines of the same state go into crash and freeze reports, which outlive this file's
        // 5-second rhythm. Sent only when they change; diagnostics copies them into its text.
        let note = """
              input \(context.settings.mulg.controls.playMode.rawValue), routing \(router.mode.rawValue), \
            native interface \(router.nativeInterfaceActive), viewport \(Int(bounds.width))×\(Int(bounds.height))
              held inputs \(dispatcher.heldInputCount), key presses \(router.gameplayKeyPresses), \
            mouse presses \(router.gameplayMousePresses), profile \(keymapFile?.deletingPathExtension().lastPathComponent ?? "none")
            """
        if note != lastDiagnosticNote {
            lastDiagnosticNote = note
            context.events.publish(DiagnosticNote(module: id, text: note))
        }
        // Freeze main-actor values here; encoding, sorting and disk writes belong to the
        // utility writer, which keeps only the latest pending report for each file.
        ReportWriter.shared.writeJSONObject(report, to: context.paths.diagnosticsDirectory(for: context.bundleIdentifier)
            .appendingPathComponent("controls.json"))
    }

    /// Native resize, surface replacement and pixel changes use the same atomic reflow.
    /// Sampling on input/frame boundaries catches renderers that publish sizes after layout.
    private func refreshControlGeometry() {
        guard !closing, let injector, let router else { return }
        let sample = ViewportSample(metrics: injector.screenMetrics, revision: GameViewport.shared.geometryRevision)
        guard sample.isValid else { return }
        guard sample != builtViewport || pendingViewport != nil else { return }
        queueViewport(sample, router: router)
    }

    private func queueViewport(_ sample: ViewportSample, router: InputRouter) {
        guard !closing else { return }
        guard pendingViewport != sample else { return }
        pendingViewport = sample
        cancelHUDConfirmation()
        hudTracker?.suspendForViewportChange()
        if !viewportReflowing {
            viewportReflowing = true
            injector?.setSuspended(true)
            dispatcher.setLiveResizing(true)
        }
        router.viewportChanged()
        viewportTask?.cancel()
        viewportTask = nil
        guard !liveResizing else { return }
        viewportTask = Task { @MainActor [weak self, weak router] in
            let clock = ContinuousClock()
            var previous: ViewportSample?
            var stableSince = clock.now
            let mismatchDeadline = clock.now + .milliseconds(750)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled, let self, let router, let injector = self.injector,
                      !self.closing, !self.liveResizing else { return }
                let current = ViewportSample(metrics: injector.screenMetrics, revision: GameViewport.shared.geometryRevision)
                guard current.isValid else { continue }
                if current != previous {
                    previous = current
                    stableSince = clock.now
                    self.pendingViewport = current
                }
                // UIKit bounds often arrive before the actual drawable adopts the new aspect.
                // Give that transition time; persistent anisotropic output has its own projection.
                guard stableSince.duration(to: clock.now) >= .milliseconds(100),
                      current.rendererMatchesPoints || clock.now >= mismatchDeadline else { continue }
                self.viewportTask = nil
                if let map = self.keymap { _ = self.rememberReferenceCanvas(map, metrics: current.metrics) }
                if current.layoutGeometry.proportionsChanged(from: self.builtViewport?.layoutGeometry) {
                    self.proportionChangeCount += 1
                }
                self.builtViewport = current
                self.builtMetrics = current.metrics
                self.builtGeometryRevision = current.revision
                self.pendingViewport = nil
                router.viewportChanged()
                // Main actor: no physical input can interleave the group-wide geometry commit.
                injector.setSuspended(false)
                self.dispatcher.commitViewport(to: current.metrics)
                self.viewportReflowing = false
                self.viewportCommitCount += 1
                self.hudTracker?.viewportCommitted(current.layoutGeometry)
                self.hudTracker?.recheck()
                return
            }
        }
    }

    private func observeWindowResize(keymap: KeymappingData, injector: any TouchInjecting,
                                     environment: any InputEnvironment, router: InputRouter) {
        context?.bridge?.observeLiveResize?({ [weak self, weak router] resizing in
            guard let self, !self.closing, let router else { return }
            self.liveResizing = resizing
            self.viewportTask?.cancel()
            self.viewportTask = nil
            // Always resample at the end, even if the final bounds match an intermediate sample.
            self.pendingViewport = nil
            let current = ViewportSample(metrics: injector.screenMetrics, revision: GameViewport.shared.geometryRevision)
            if current.isValid { self.queueViewport(current, router: router) }
        })
        let names = [GameViewport.changed, GameViewport.geometryChanged,
                     Notification.Name("NSWindowDidEndLiveResizeNotification"),
                     Notification.Name("NSWindowDidEnterFullScreenNotification"),
                     Notification.Name("NSWindowDidExitFullScreenNotification"), UIWindow.didBecomeKeyNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshControlGeometry() }
            })
        }
    }

    /// Camera movement from GCMouse instead of the cursor (controls.rawMouse): unaccelerated, and
    /// read on GameController's owner queue without moving the game's native callbacks. A game
    /// that sets its own movement handler keeps it; the router then falls back.
    private func startRawMouse(router: InputRouter) {
        #if canImport(GameController)
        let raw = RawMouse()
        router.rawMouse = raw
        let attach: @MainActor (GCMouse?) -> Void = { [weak self, weak router] mouse in
            guard self?.closing != true, let input = mouse?.mouseInput,
                  input.mouseMovedHandler == nil else { return }
            // handlerQueue belongs to the entire device, including native button/scroll
            // callbacks. Borrow the empty movement slot without moving those callbacks.
            router?.rawMouseConnected(raw)
            input.mouseMovedHandler = { @Sendable [weak router] _, dx, dy in
                // GameController reports up as positive dy, the cursor down. RawMouseCalibration
                // checks both axes and the scale against the cursor before GCMouse is used.
                guard raw.add(dx: CGFloat(dx), dy: CGFloat(-dy)) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { router?.rawMouseMoved() } }
            }
        }
        attach(GCMouse.current)
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { notification in
            nonisolated(unsafe) let mouse = notification.object as? GCMouse
            MainActor.assumeIsolated { attach(mouse) }
        })
        #endif
    }

    /// Upstream simulateGCMouseDisconnect: games that listen for mouse connections are told the
    /// mouse went away again.
    private func simulateMouseDisconnect() {
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { notification in
            // Delivered on the main queue; the object is only read there.
            nonisolated(unsafe) let object = notification.object
            MainActor.assumeIsolated {
                let mouse = object
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1))
                    NotificationCenter.default.post(name: .GCMouseDidDisconnect, object: mouse)
                }
            }
        })
    }
    #endif
}

// MARK: - Menu: editor, keymaps, pointer (upstream MenuController)

#if canImport(UIKit) && !os(watchOS)
extension ControlsModule {
    enum Command {
        static let calibrateMovement = "controls.calibrateMovement"
        static let confirmHUDAnchor = "controls.confirmHUDAnchor"
        static let recheckHUDAnchors = "controls.recheckHUDAnchors"
        static let forgetHUDAnchors = "controls.forgetHUDAnchors"
        static let toggleHUDTracking = "controls.toggleHUDTracking"
        static let toggleEditor = "controls.toggleEditor"
        static let deleteElement = "controls.deleteElement"
        static let upsizeElement = "controls.upsizeElement"
        static let downsizeElement = "controls.downsizeElement"
        static let joystickMode = "controls.joystickMode"
        static let buttonHold = "controls.buttonHold"
        static let nextLayer = "controls.nextLayer"
        static let newLayer = "controls.newLayer"
        static let resumeGameplay = "controls.resumeGameplay"
        static let hidePointer = "controls.hidePointer"
        static let previousKeymap = "controls.previousKeymap"
        static let nextKeymap = "controls.nextKeymap"
        static let profilePrefix = "controls.profile."
    }

    /// The Controls menu: one command to edit, the profiles, and the pointer. The rest (HUD
    /// anchors, movement calibration) sits in one "Advanced" submenu, and the editing shortcuts of
    /// the built-in editor appear only while that editor is open.
    func registerMenuCommands(_ context: ModuleContext, bridge: any MacBridge) {
        let commands: [(MenuCommand, @MainActor () -> Void)] = [
            (MenuCommand(id: Command.toggleEditor, title: "Edit Controls…", symbol: "square.and.pencil",
                         key: "K", section: "editor"), { [weak self] in self?.toggleEditor() }),
            (MenuCommand(id: Command.previousKeymap, title: "Previous Profile", symbol: "arrow.up.square",
                         key: "[", section: "profiles"), { [weak self] in self?.switchKeymap(by: -1) }),
            (MenuCommand(id: Command.nextKeymap, title: "Next Profile", symbol: "arrow.down.square",
                         key: "]", section: "profiles"), { [weak self] in self?.switchKeymap(by: 1) }),
            (MenuCommand(id: Command.resumeGameplay, title: "Resume Gameplay Controls", symbol: "gamecontroller",
                         key: "", section: "pointer"), { [weak self] in self?.router?.resumeGameplay() }),
            (MenuCommand(id: Command.hidePointer, title: "Hide Mouse Pointer", symbol: "pointer.arrow.slash",
                         key: ".", section: "pointer"), { [weak bridge] in bridge?.hideCursorUntilMouseMoves() }),
            (MenuCommand(id: Command.calibrateMovement, title: "Calibrate Movement Joystick", symbol: "scope",
                         key: "C", modifiers: [.command, .shift], section: "advanced", submenu: "Advanced"),
                { [weak self] in self?.beginMovementCalibration() }),
            (MenuCommand(id: Command.recheckHUDAnchors, title: "Recheck HUD Anchors", symbol: "viewfinder",
                         key: "H", modifiers: [.command, .shift], section: "advanced", submenu: "Advanced"),
                { [weak self] in self?.hudTracker?.recheck(showResult: true) }),
            (MenuCommand(id: Command.toggleHUDTracking, title: "Pause/Resume HUD Tracking", symbol: "pause.circle",
                         key: "H", modifiers: [.command, .option], section: "advanced", submenu: "Advanced"),
                { [weak self] in self?.hudTracker?.toggle() }),
            (MenuCommand(id: Command.confirmHUDAnchor, title: "Override Selected HUD Anchor…", symbol: "scope",
                         key: "A", modifiers: [.command, .shift], section: "advanced", submenu: "Advanced"),
                { [weak self] in self?.confirmSelectedHUDAnchor() }),
            (MenuCommand(id: Command.forgetHUDAnchors, title: "Reset This Profile’s HUD Learning", symbol: "arrow.uturn.backward",
                         key: "A", modifiers: [.command, .option, .shift], section: "advanced", submenu: "Advanced"),
                { [weak self] in self?.forgetHUDAnchors() })
        ]
        for (command, action) in commands {
            do {
                try context.menus.register(command, owner: id, action: action)
            } catch {
                context.logger(for: id).error("Menu command \(command.id, privacy: .public) not added: \(String(describing: error), privacy: .public)")
            }
        }
        refreshProfileMenu()
    }

    /// The editing shortcuts of the built-in editor, in the menu only while it is open.
    private func registerBuiltInEditorCommands() {
        guard let context else { return }
        let commands: [(MenuCommand, @MainActor () -> Void)] = [
            (MenuCommand(id: Command.deleteElement, title: "Delete selected element", symbol: "trash.fill",
                         key: MenuCommand.Key.delete, section: "editing"), { [weak self] in self?.editor.removeSelected() }),
            (MenuCommand(id: Command.upsizeElement, title: "Upsize selected element", symbol: "square.resize.up",
                         key: MenuCommand.Key.upArrow, section: "editing"), { [weak self] in self?.editor.resizeSelected(larger: true) }),
            (MenuCommand(id: Command.downsizeElement, title: "Downsize selected element", symbol: "square.resize.down",
                         key: MenuCommand.Key.downArrow, section: "editing"), { [weak self] in self?.editor.resizeSelected(larger: false) }),
            (MenuCommand(id: Command.joystickMode, title: "Switch joystick between fixed and floating", symbol: "dpad",
                         key: "J", section: "editing"), { [weak self] in self?.editor.toggleJoystickMode() }),
            (MenuCommand(id: Command.buttonHold, title: "Switch button between hold and toggle", symbol: "hand.tap",
                         key: "J", modifiers: [.command, .shift], section: "editing"), { [weak self] in self?.editor.toggleButtonHold() }),
            (MenuCommand(id: Command.nextLayer, title: "Edit next layer", symbol: "square.3.layers.3d",
                         key: "L", section: "editing"), { [weak self] in self?.editor.showLayer(offset: 1) }),
            (MenuCommand(id: Command.newLayer, title: "New layer", symbol: "plus.square.on.square",
                         key: "L", modifiers: [.command, .shift], section: "editing"), { [weak self] in self?.editor.addLayer() })
        ]
        for (command, action) in commands {
            try? context.menus.register(command, owner: id, action: action)
        }
    }

    private func unregisterBuiltInEditorCommands() {
        guard let context else { return }
        for command in [Command.deleteElement, Command.upsizeElement, Command.downsizeElement, Command.joystickMode,
                        Command.buttonHold, Command.nextLayer, Command.newLayer] {
            context.menus.unregister(command)
        }
    }

    /// The Profiles submenu: one entry per profile, the active one checked. Called after any change.
    func refreshProfileMenu() {
        guard let context else { return }
        for index in 0..<Self.profileMenuLimit { context.menus.unregister(Command.profilePrefix + String(index)) }
        for (index, profile) in profileList().prefix(Self.profileMenuLimit).enumerated() {
            let name = profile.name
            try? context.menus.register(
                MenuCommand(id: Command.profilePrefix + String(index), title: name, key: "", section: "profiles",
                            submenu: "Profiles", isChecked: profile.isActive),
                owner: id) { [weak self] in self?.switchToProfile(named: name) }
        }
    }

    static let profileMenuLimit = 16

    /// Measures the actual game HUD instead of assuming an imported joystick is centered.
    public func beginMovementCalibration() {
        cancelHUDConfirmation()
        hudTracker?.suspend()
        guard let context, let router, !router.nativeInterfaceActive,
              context.settings.mulg.controls.playMode == .touch else {
            context?.notices.show(Notice("Movement calibration unavailable",
                lines: ["Use a touchscreen keymap with a movement joystick."], style: .warning))
            return
        }
        let selected = editor.model?.elements.first(where: { $0.id == editor.model?.focused })
        let preferredLayer = editor.model?.currentLayer ?? dispatcher.activeLayer
        if editor.isOpen, !closeEditor(save: true) { return }
        guard let map = keymap,
              let target = movementTarget(in: map, selected: selected, preferredLayer: preferredLayer) else {
            context.notices.show(Notice("Movement calibration unavailable",
                lines: ["Add a movement joystick, or select a joystick in the keymap editor."], style: .warning))
            return
        }
        movementCalibrationTarget = target
        movementCalibrationActive = true
        movementCalibrationCenter = nil
        movementCalibrationMetrics = nil
        router.setEditorOpen(true)
        context.notices.show(Notice("Calibrate movement: center",
            lines: ["Click the exact center of the game's movement joystick.",
                    "Then click the outer edge of its circle. Escape cancels."], duration: .seconds(30)))
    }

    private func cancelMovementCalibration() {
        guard movementCalibrationActive else { return }
        movementCalibrationActive = false
        movementCalibrationTarget = nil
        movementCalibrationCenter = nil
        movementCalibrationMetrics = nil
        router?.setEditorOpen(false)
        context?.notices.show(Notice("Movement calibration cancelled", duration: .seconds(2)))
    }

    private func handleMovementCalibrationClick(button: Int, pressed: Bool) -> Bool {
        // Consume the final mouse-up even after calibration has finished.
        if button == 0, !pressed, calibrationMouseRelease {
            calibrationMouseRelease = false
            return true
        }
        guard movementCalibrationActive else { return false }
        guard button == 0, pressed else { return true }
        calibrationMouseRelease = true
        guard let point = environment?.cursorPoint(), let injector else { return true }
        let metrics = injector.screenMetrics
        if let center = movementCalibrationCenter {
            guard metrics == movementCalibrationMetrics else {
                movementCalibrationCenter = nil
                movementCalibrationMetrics = nil
                context?.notices.show(Notice("Window changed",
                    lines: ["Click the joystick center again, then its outer edge."], duration: .seconds(15)))
                return true
            }
            if calibrateMovement(center: center, edge: point, metrics: metrics) {
                movementCalibrationActive = false
                movementCalibrationTarget = nil
                movementCalibrationCenter = nil
                movementCalibrationMetrics = nil
                router?.setEditorOpen(false)
                context?.notices.show(Notice("Movement joystick calibrated",
                    lines: ["Center and radius saved for this window shape.",
                            "Measurements at other shapes are retained and blended automatically."], duration: .seconds(4)))
            }
        } else {
            movementCalibrationCenter = point
            movementCalibrationMetrics = metrics
            context?.notices.show(Notice("Calibrate movement: radius",
                lines: ["Click the outer edge of the movement joystick's circle.", "Escape cancels."],
                duration: .seconds(30)))
        }
        return true
    }

    /// Save first, then apply to live actions. A failed write preserves the active keymap.
    @discardableResult
    public func calibrateMovement(center: CGPoint, edge: CGPoint, metrics: ScreenMetrics) -> Bool {
        let scaleX = max(0.000001, metrics.horizontalUnitScale)
        guard let calibration = JoystickCalibration(
                  center: CGPoint(x: center.x / scaleX, y: center.y),
                  edge: CGPoint(x: edge.x / scaleX, y: edge.y),
                  width: metrics.canvasWidth, height: metrics.height),
              var map = keymap, let store, let file = keymapFile,
              let target = movementCalibrationTarget ?? movementTarget(in: map),
              let original = joystick(in: map, at: target) else {
            context?.notices.show(Notice("Invalid joystick measurement",
                lines: ["Click the neutral center, then a point on the outer circle."], style: .warning))
            return false
        }
        var measured = original
        map.mulgHUDAnchors = map.mulgHUDAnchors?.filter {
            $0.address.layer != target.layer || $0.address.index != target.index
                || ($0.address.kind != .digitalJoystick && $0.address.kind != .analogJoystick)
        }
        measured.recordCalibration(calibration)
        measured.transform = calibration.transform.fitted(from: calibration.aspectRatio,
            to: map.mulgAspectRatio ?? calibration.aspectRatio)
        if target.layer == 0 {
            map.joystickModel[target.index] = measured
        } else {
            guard var layers = map.mulgLayers, layers.indices.contains(target.layer - 1),
                  layers[target.layer - 1].joystickModel.indices.contains(target.index) else { return false }
            layers[target.layer - 1].joystickModel[target.index] = measured
            map.mulgLayers = layers
        }
        if let problem = store.write(map, to: file) {
            context?.logger(for: id).error("Joystick calibration not saved: \(String(describing: problem), privacy: .public)")
            context?.notices.show(Notice("Movement calibration not saved",
                lines: ["The keymap could not be written. Try again or press Escape."], style: .warning))
            return false
        }
        use(map)
        return true
    }

    private func joystickList(in map: KeymappingData, layer: Int) -> [JoystickElement] {
        if layer == 0 { return map.joystickModel }
        guard let layers = map.mulgLayers, layers.indices.contains(layer - 1) else { return [] }
        return layers[layer - 1].joystickModel
    }

    private func movementTarget(in map: KeymappingData, selected: KeymapEditorModel.Element? = nil,
                                preferredLayer: Int = 0) -> MovementTarget? {
        func target(_ element: JoystickElement, layer: Int, index: Int) -> MovementTarget {
            MovementTarget(layer: layer, index: index,
                keys: [element.upKeyCode, element.downKeyCode, element.leftKeyCode, element.rightKeyCode],
                name: element.keyName)
        }
        // Selection wins, including analog sticks and controls in any keymap layer.
        if let selected, case .joystick(let selectedStick) = selected.kind {
            let list = joystickList(in: map, layer: selected.layer)
            if let index = list.firstIndex(where: {
                $0.keyName == selectedStick.keyName && $0.upKeyCode == selectedStick.upKeyCode
                    && $0.downKeyCode == selectedStick.downKeyCode && $0.leftKeyCode == selectedStick.leftKeyCode
                    && $0.rightKeyCode == selectedStick.rightKeyCode
            }) { return target(list[index], layer: selected.layer, index: index) }
            return nil // Do not silently calibrate another control after a failed selection.
        }
        for layer in preferredLayer == 0 ? [0] : [preferredLayer, 0] {
            let list = joystickList(in: map, layer: layer)
            let index = list.firstIndex(where: { !$0.isAnalog && $0.upKeyCode == 26 })
                ?? list.firstIndex(where: { !$0.isAnalog })
                ?? list.firstIndex(where: { $0.keyName == "Left Thumbstick" })
            if let index { return target(list[index], layer: layer, index: index) }
        }
        return nil
    }

    private func joystick(in map: KeymappingData, at target: MovementTarget) -> JoystickElement? {
        let list = joystickList(in: map, layer: target.layer)
        guard list.indices.contains(target.index) else { return nil }
        let element = list[target.index]
        guard element.keyName == target.name,
              [element.upKeyCode, element.downKeyCode, element.leftKeyCode, element.rightKeyCode] == target.keys else { return nil }
        return element
    }

    /// ⌘K: opens the editor over the game, or saves the profile and closes it.
    public func toggleEditor() {
        guard let context, let router else { return }
        cancelHUDConfirmation()
        hudTracker?.suspend()
        cancelMovementCalibration()
        if editor.isOpen {
            closeEditor(save: true)
            return
        }
        let opened: any ControlEditing = context.controlEditor ?? builtInEditor
        sessionEditor = opened
        router.editor = opened
        router.setEditorOpen(true)
        (controllerInput as? ControllerInput)?.editorSink = { [weak self] name in
            self?.editor.controllerElement(name)
        }
        guard opened.open(keymap: keymap ?? KeymappingData(bundleIdentifier: context.bundleIdentifier),
                          profile: activeProfileName, host: makeEditingHost()) else {
            endEditorSession()
            return
        }
        if (opened as AnyObject) === builtInEditor {
            registerBuiltInEditorCommands()
            context.notices.show(Notice("Controls Editor",
                                        lines: ["Click an empty area to add a control.", "Click a control, then press a key to bind it."],
                                        duration: .seconds(4)))
        }
    }

    /// Everything that was set up for an editor session, undone: input goes back to the game.
    private func endEditorSession() {
        (controllerInput as? ControllerInput)?.editorSink = nil
        unregisterBuiltInEditorCommands()
        router?.editor = nil
        sessionEditor = nil
        router?.setEditorOpen(false)
    }

    @discardableResult
    private func closeEditor(save: Bool) -> Bool {
        guard let context, let model = editor.model else { return false }
        if save, model.hasChanges {
            if let problem = saveDraft(model.keymap()) {
                context.notices.show(Notice("Profile not saved", lines: [problem.message, "Your draft is still open."], style: .warning))
                return false
            }
            context.notices.show(Notice("Profile saved", duration: .seconds(2)))
        }
        guard let result = editor.close() else { return false }
        if save, result.changed {
            use(result.keymap)
        }
        endEditorSession()
        hudTracker?.recheck()
        refreshProfileMenu()
        if let map = keymap, context.settings.mulg.controls.playMode == .touch, !map.hasTouchControls {
            context.notices.show(Notice("“\(activeProfileName)” has no controls yet",
                                        lines: ["Press ⌘K to add some, or pick another profile."], style: .warning, duration: .seconds(5)))
        }
        return true
    }

    // MARK: Profiles

    private var activeProfileName: String {
        keymapFile?.deletingPathExtension().lastPathComponent ?? "default"
    }

    static func controlCount(_ map: KeymappingData) -> Int {
        let layers = (map.mulgLayers ?? []).reduce(0) {
            $0 + $1.buttonModels.count + $1.draggableButtonModels.count + $1.joystickModel.count + $1.mouseAreaModel.count
        }
        return map.buttonModels.count + map.draggableButtonModels.count + map.joystickModel.count
            + map.mouseAreaModel.count + layers
    }

    /// The game's profiles for the menu and the editor, the one in use marked.
    func profileList() -> [ControlProfile] {
        guard let store else { return [] }
        let active = keymapFile.map(store.profileName(of:))
        return store.orderedKeymapFiles().map { file in
            let loaded = store.load(file)
            let name = store.profileName(of: file)
            return ControlProfile(name: name, isActive: name == active,
                                  controlCount: loaded.problems.isEmpty ? Self.controlCount(loaded.keymap) : 0)
        }
    }

    /// Writes an editor draft into the active profile, keeping a backup of what was there. Nil on
    /// success; otherwise why not, and the file is as it was.
    private func saveDraft(_ draft: KeymappingData) -> ControlProfileError? {
        guard let store, let file = keymapFile else {
            return ControlProfileError("The profile file is unavailable.")
        }
        store.backUp(file)
        if let problem = store.write(draft, to: file) {
            context?.logger(for: id).error("Profile not saved: \(String(describing: problem), privacy: .public)")
            return ControlProfileError("The file for “\(activeProfileName)” could not be written.")
        }
        return nil
    }

    /// Makes another profile the active one while the editor is open. The draft of the profile being
    /// left is saved first when `draft` is given; a profile that cannot be read is left alone.
    private func switchProfileInEditor(_ name: String, saving draft: KeymappingData?)
        -> Result<KeymappingData, ControlProfileError> {
        guard let store else { return .failure(ControlProfileError("Controls are not available.")) }
        let file = store.keymapFile(named: name)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return .failure(ControlProfileError("The profile “\(name)” was not found."))
        }
        let loaded = store.load(file)
        guard loaded.problems.isEmpty else {
            return .failure(ControlProfileError("The profile “\(name)” could not be read, so it was left as it is."))
        }
        // As with ⌘[ and ⌘]: a touchscreen game can't use a controller-only profile. An empty profile
        // (a new blank one) is allowed, since it is there to be filled.
        if context?.settings.mulg.controls.playMode == .touch, !loaded.keymap.hasTouchControls,
           !(loaded.keymap.mulgControllerBindings ?? []).isEmpty {
            return .failure(ControlProfileError("“\(name)” is for Controller mode. Change the play mode in Mulg to use it."))
        }
        if let draft, let problem = saveDraft(draft) { return .failure(problem) }
        keymapFile = file
        use(loaded.keymap)
        store.makeDefault(file)
        refreshProfileMenu()
        return .success(keymap ?? loaded.keymap)
    }

    /// Creates a profile while the editor is open and makes it the active one. `keymap` is copied
    /// into it, or it starts empty. The name is made unique; no existing profile is replaced.
    private func createProfileInEditor(_ name: String, from keymap: KeymappingData?, saving draft: KeymappingData?)
        -> Result<(name: String, keymap: KeymappingData), ControlProfileError> {
        guard let context, let store else { return .failure(ControlProfileError("Controls are not available.")) }
        var base = keymap ?? KeymappingData(bundleIdentifier: context.bundleIdentifier)
        if keymap == nil { base.mulgAspectRatio = injector?.screenMetrics.renderAspect }
        if let draft, let problem = saveDraft(draft) { return .failure(problem) }
        switch store.createProfile(named: name, keymap: base) {
        case .failure(let problem):
            context.logger(for: id).error("Profile not created: \(String(describing: problem), privacy: .public)")
            return .failure(ControlProfileError("The new profile could not be saved."))
        case .success(let file):
            keymapFile = file
            use(base)
            store.makeDefault(file)
            refreshProfileMenu()
            return .success((store.profileName(of: file), self.keymap ?? base))
        }
    }

    /// The editor asks to end the session.
    private func finishEditing(save: Bool) {
        guard editor.isOpen else { return }
        closeEditor(save: save)
    }

    private func makeEditingHost() -> ControlEditingHost {
        let unavailable = ControlProfileError("Controls are not available.")
        return ControlEditingHost(
            profiles: { [weak self] in self?.profileList() ?? [] },
            switchProfile: { [weak self] name, draft in
                self?.switchProfileInEditor(name, saving: draft) ?? .failure(unavailable)
            },
            createProfile: { [weak self] name, keymap, draft in
                self?.createProfileInEditor(name, from: keymap, saving: draft) ?? .failure(unavailable)
            },
            finish: { [weak self] save in self?.finishEditing(save: save) })
    }

    /// The Profiles menu: switch to a profile by name (the editor, if open, is saved and reopened).
    func switchToProfile(named name: String) {
        guard let context, let store, let current = keymapFile else { return }
        let target = store.keymapFile(named: name)
        guard target.deletingPathExtension().lastPathComponent != current.deletingPathExtension().lastPathComponent else {
            return
        }
        let files = store.orderedKeymapFiles().map(store.profileName(of:))
        guard let to = files.firstIndex(of: name), let from = files.firstIndex(of: activeProfileName) else {
            context.notices.show(Notice("Profile not found", lines: [name], style: .warning))
            return
        }
        switchKeymap(by: to - from)
    }

    /// ⌘[ and ⌘]: the previous or next of the game's profiles. An open editor is saved,
    /// then reopened on the new profile, as upstream did.
    public func switchKeymap(by offset: Int) {
        guard let context, let store, let current = keymapFile,
              let next = store.keymapFile(offset: offset, from: current) else { return }
        // Checked before the editor closes, so a failed switch leaves the editor open.
        guard next != current else {
            context.notices.show(Notice("This game has one profile", duration: .seconds(2)))
            return
        }
        let loaded = store.load(next)
        guard loaded.problems.isEmpty else {
            context.notices.show(Notice("Profile could not be loaded", lines: [next.deletingPathExtension().lastPathComponent],
                                        style: .warning))
            return
        }
        if context.settings.mulg.controls.playMode == .touch, !loaded.keymap.hasTouchControls {
            context.notices.show(Notice("This profile requires Controller mode",
                lines: ["Keep a touchscreen profile selected when the game only offers Touchscreen."], style: .warning))
            return
        }
        cancelMovementCalibration()
        let editorWasOpen = editor.isOpen
        if editorWasOpen, !closeEditor(save: true) { return }
        keymapFile = next
        use(loaded.keymap)
        store.makeDefault(next)
        refreshProfileMenu()
        context.notices.show(Notice("Profile: \(next.deletingPathExtension().lastPathComponent)", duration: .seconds(2)))
        if editorWasOpen {
            toggleEditor()
        }
    }

    /// Makes `keymap` the one in use: actions, mode rules and controller bindings.
    private func use(_ keymap: KeymappingData) {
        guard let router, let injector, let environment, let context else { return }
        cancelHUDConfirmation()
        var keymap = keymap
        if GenshinDefaults.applies(to: context.bundleIdentifier) {
            keymap = GenshinDefaults.correctedTouchInputs(keymap)
        }
        if StarRailDefaults.applies(to: context.bundleIdentifier) {
            keymap = StarRailDefaults.adaptiveTouchLayout(keymap)
        }
        if GenshinDefaults.applies(to: context.bundleIdentifier) && keymap.mulgControllerBindings == nil {
            keymap.mulgControllerBindings = GenshinDefaults.controllerBindings
        }
        self.keymap = keymap
        applyKeymapWindowShape(keymap, context: context)
        router.prepareForKeymapChange()
        buildActions(keymap: keymap, injector: injector, environment: environment, router: router)
        router.keymapRebuilt(self.keymap ?? keymap)
        virtualController?.rebind(keymap.mulgControllerBindings ?? [])
    }

    private func cancelHUDConfirmation() {
        guard hudConfirmationID != nil else { return }
        hudConfirmationID = nil
        hudTracker?.cancel()
        if !editor.isOpen { router?.setEditorOpen(false) }
    }

    private func confirmSelectedHUDAnchor() {
        guard let context, let router, let tracker = hudTracker, let injector,
              context.settings.mulg.controls.playMode != .virtualController, !router.nativeInterfaceActive,
              let model = editor.model, let address = model.selectedHUDAddress,
              let target = model.keymap().hudTarget(at: address, aspect: injector.screenMetrics.renderAspect) else {
            context?.notices.show(Notice("Select a HUD control", lines: ["Open ⌘K, center a button or joystick on its visible HUD, select it, then press ⌘⇧A."], style: .warning))
            return
        }
        guard closeEditor(save: true), keymap?.hudTarget(at: address, aspect: injector.screenMetrics.renderAspect)?.bindingSignature == target.bindingSignature else { return }
        cancelMovementCalibration()
        let token = UUID(), file = keymapFile
        hudConfirmationID = token
        router.setEditorOpen(true)
        context.notices.show(Notice("Confirming HUD anchor", lines: ["Keep the visible HUD still for five seconds. Screen Recording permission may be requested."], duration: .seconds(3)))
        let isStick = address.kind == .digitalJoystick || address.kind == .analogJoystick
        let span = min(0.18, max(0.05, Double(target.transform.size) / 100
            * max(1, injector.screenMetrics.renderAspect) * (isStick ? 0.65 : 1.15)))
        tracker.confirm(target: target, spanInHeights: span) { [weak self, weak router] anchor, error in
            guard let self, self.hudConfirmationID == token else { return }
            self.hudConfirmationID = nil
            router?.setEditorOpen(false)
            guard self.keymapFile == file, let anchor, var map = self.keymap,
                  map.hudTarget(at: address, aspect: anchor.referenceAspect)?.bindingSignature == anchor.bindingSignature else {
                context.notices.show(Notice("HUD anchor not confirmed", lines: [error ?? "The selected control changed. Confirm its current position again."], style: .warning))
                return
            }
            var anchors = map.validHUDAnchors.filter { $0.address != address }
            guard anchors.count < ControlHUDAnchor.maximumCount else {
                context.notices.show(Notice("HUD reference limit", lines: ["This map already has \(ControlHUDAnchor.maximumCount) confirmed references."], style: .warning)); return
            }
            anchors.append(anchor); map.mulgHUDAnchors = anchors
            guard let store = self.store, let file,
                  store.write(map, to: file) == nil else {
                context.notices.show(Notice("HUD anchor not saved", lines: ["The keymap file could not be written. The original mapping is still active."], style: .warning)); return
            }
            self.use(map)
            context.notices.show(Notice("HUD anchor confirmed", lines: ["This control will be checked after resizing. Uncertain alignment keeps your original mapping."], duration: .seconds(4)))
        }
    }

    private func forgetHUDAnchors() {
        guard let context, let store, let file = keymapFile else { return }
        if editor.isOpen, !closeEditor(save: true) { return }
        cancelHUDConfirmation()
        guard var map = keymap else { return }
        map.mulgHUDAnchors = nil
        guard store.write(map, to: file) == nil else {
            context.notices.show(Notice("HUD anchors not reset", lines: ["The keymap file could not be written."], style: .warning)); return
        }
        guard hudTracker?.resetAutomaticReferences() ?? true else {
            use(map)
            context.notices.show(Notice("HUD cache not reset", lines: ["The automatic reference cache could not be removed. The map itself was preserved."], style: .warning)); return
        }
        use(map)
        context.notices.show(Notice("HUD learning reset", lines: ["Controls will be detected automatically again. Your original bindings and layout calibrations are kept."], duration: .seconds(3)))
    }
}
#endif

// MARK: - Gyro recentre (§14.3)

extension ControlsModule {
    /// A hotkey that levels the virtual device again, only when the virtual gyro is in use.
    func registerGyroRecenter(_ context: ModuleContext) {
        let gyro = context.settings.mulg.controls.gyro
        guard gyro.source != .off else { return }
        guard let hotkey = Hotkey(gyro.recenterHotkey) else {
            context.logger(for: id).error("Invalid gyro recentre hotkey '\(gyro.recenterHotkey, privacy: .public)'")
            return
        }
        do {
            try context.hotkeys.register(hotkey, owner: id, title: "Recentre gyro") { [weak context] in
                mulg_motion_recenter()
                context?.notices.show(Notice("Gyro recentred", duration: .seconds(1)))
            }
        } catch {
            context.logger(for: id).error("Gyro recentre hotkey \(hotkey.description, privacy: .public) is taken")
        }
    }
}

#if canImport(UIKit) && !os(watchOS)
extension UIResponder {
    private static weak var mulgFoundResponder: UIResponder?

    /// The key window's first responder, found the way UIKit routes an action sent to nil.
    static var mulgCurrentFirstResponder: UIResponder? {
        mulgFoundResponder = nil
        UIApplication.shared.sendAction(#selector(mulgCaptureFirstResponder(_:)), to: nil, from: nil, for: nil)
        defer { mulgFoundResponder = nil }
        return mulgFoundResponder
    }

    @objc private func mulgCaptureFirstResponder(_ sender: Any?) {
        UIResponder.mulgFoundResponder = self
    }
}
#endif
