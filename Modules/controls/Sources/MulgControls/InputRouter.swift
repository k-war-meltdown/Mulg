import CoreGraphics
import Darwin
import Foundation
import MulgContracts
import MulgControlsHooks
import MulgEngine
import Synchronization

/// Everything the router needs from the outside, so it can be tested without a Mac window.
@MainActor
public protocol InputEnvironment: AnyObject {
    /// Cursor position on the game's screen, or nil when outside the game.
    func cursorPoint() -> CGPoint?
    /// Hide and capture for relative camera input, or restore the visible pointer.
    func setCursorHidden(_ hidden: Bool)
    /// Whether the player showed the cursor with the cursor key or a middle click; only then does
    /// the window border hold the pointer (`engine.confinePointer`).
    func setCursorReleasedByPlayer(_ released: Bool)
    var isFullscreen: Bool { get }
    func setMenuBarVisible(_ visible: Bool)
}

public extension InputEnvironment {
    func setCursorReleasedByPlayer(_ released: Bool) {}
}

/// Routes every input from the Mac to the game (PLAN.md §6.1, §14).
///
/// Order for a key press:
/// 1. in-game hotkeys (engine) — never reach the game;
/// 2. ⌘ held — menu shortcuts, passed to the app;
/// 3. text input or keymapping off — passed to the game untouched;
/// 4. the cursor key and the middle button — the only mode changes (§14.2);
/// 5. the virtual controller (virtual-controller or hybrid mode) or the gyro keys;
/// 6. the keymap's touch actions.
///
/// Everything runs on the main thread in the event's own turn, with no queue hops, and mouse
/// movement is coalesced to at most 240 updates per second (upstream: 125). Movement still
/// waiting when a display-link frame starts is sent at once (`frameStarts`).
@MainActor
public final class InputRouter {
    public private(set) var modes: ControlModeMachine
    public let dispatcher: ActionDispatcher
    public let fakeMouse: FakeMouseAction
    private let hotkeys: HotkeyCenter
    private let events: EventBus
    private let environment: any InputEnvironment
    private var settings: ControlsSettings
    private var controlMap: KeymappingData?
    private var bindingGraph: ControlBindingGraph?
    private let bundleIdentifier: String
    public private(set) var controlPlan: AdaptiveControlPlan?
    private var sensitivity: CGFloat
    private let enableScrollWheel: Bool
    private var measureLatency: Bool
    private let cursorKeyCodes: Set<UInt16>
    private var heldCursorKeys: Set<UInt16> = []
    private let walkKeyCodes: Set<UInt16>
    private var heldWalkKeys: Set<UInt16> = []
    private var mappedKeys: Set<UInt16> = []
    public var virtualController: VirtualController?
    var onLayerChanged: ((Int) -> Void)?
    var onMappedModeChanged: (() -> Void)?
    var controllerTouchMappingActive: Bool {
        focused && !nativeInterfaceActive && touchMappingAvailable && settings.playMode != .virtualController
            && (mode == .camera || mode == .cursor)
    }
    private var heldLayers = HeldControlLayers()
    public var gestures: TrackpadGestures?
    var touchMappingAvailable = true
    /// Receives keys and mouse buttons while the keymap editor is open.
    public weak var editor: (any KeymapEditorInput)?
    private var ctrlModifiedKeys: [UInt16] = []

    // Mouse coalescing (upstream limited the rate to 125 Hz for games that misbehave at 1000 Hz).
    static let maximumMouseRate: Double = 240
    private var lastMouseDispatch: UInt64 = 0
    private var pendingMouse = CGVector.zero
    private var pendingMouseArrival: UInt64?
    private var lastMouseConsumed = true
    private var mouseFlushScheduled = false
    private var focused = true
    private var stopped = false
    private var started = false
    public private(set) var gameplayKeyPresses = 0
    public private(set) var gameplayMousePresses = 0
    /// Physical buttons pressed in camera mode must release the same mapped action,
    /// even if Option or a menu shows the cursor before mouse-up.
    private var cameraMouseButtons: Set<Int> = []
    /// Set while GCMouse movement drives the camera (controls.rawMouse).
    var rawMouse: RawMouse?
    private var cursorEventsWithoutRaw = 0
    private var rawCalibration = RawMouseCalibration()

    // Gyro keys: arrows for yaw and pitch, [ and ] for roll (§14.3).
    private var gyroKeys: Set<UInt16> = []

    /// A new raw source can recover after the previous device/handler stopped delivering.
    /// Its units and axis directions must be learned again rather than inherited.
    func rawMouseConnected(_ source: RawMouse) {
        guard !stopped else { return }
        _ = source.take()
        rawMouse = source
        rawCalibration = RawMouseCalibration()
        cursorEventsWithoutRaw = 0
        pendingMouse = .zero
        pendingMouseArrival = nil
    }

    public init(settings: GameSettings, dispatcher: ActionDispatcher, hotkeys: HotkeyCenter, events: EventBus,
                environment: any InputEnvironment, fakeMouse: FakeMouseAction, menuKeys: Set<String>) {
        self.settings = settings.mulg.controls
        self.bundleIdentifier = settings.bundleIdentifier
        self.dispatcher = dispatcher
        self.hotkeys = hotkeys
        self.events = events
        self.environment = environment
        self.fakeMouse = fakeMouse
        sensitivity = CGFloat(settings.sensitivity / 100) * 0.6
        enableScrollWheel = settings.enableScrollWheel
        measureLatency = settings.mulg.diagnostics.measureInputLatency || settings.mulg.diagnostics.performanceOverlay
        modes = ControlModeMachine(behaviour: settings.mulg.controls.cursorKeyBehaviour,
                                   pauseForTextInput: settings.noKMOnInput,
                                   keymapUsesMouse: dispatcher.usesMouse,
                                   menuKeys: menuKeys)
        cursorKeyCodes = Self.keyCodes(forModifierName: settings.mulg.controls.cursorKey)
        walkKeyCodes = Self.keyCodes(forModifierName: settings.mulg.controls.walkModifierKey)
    }

    public func updateMeasurementSettings(_ settings: GameSettings) {
        measureLatency = settings.mulg.diagnostics.measureInputLatency || settings.mulg.diagnostics.performanceOverlay
    }

    /// Tuning and interaction policy are live; play mode, hooks and key bindings keep startup values.
    public func updateTuning(_ new: GameSettings) {
        updateMeasurementSettings(new)
        sensitivity = CGFloat(new.sensitivity / 100) * 0.6
        let source = settings.gyro.source
        let hotkey = settings.gyro.recenterHotkey
        settings.gyro = new.mulg.controls.gyro
        settings.gyro.source = source
        settings.gyro.recenterHotkey = hotkey
        virtualController?.updateStickCurve(new.mulg.controls.mouseToStick)
        settings.interactionStyle = new.mulg.controls.interactionStyle
        settings.cursorKeySwitchesCamera = new.mulg.controls.cursorKeySwitchesCamera
        refreshControlPlan()
        if !gyroKeys.isEmpty { updateGyroRate() }
    }

    func controllerMotion(x: Double, y: Double, z: Double) {
        mulg_motion_set_steady_rate(x, settings.gyro.invertPitch ? -y : y, z)
    }

    /// Both left and right keys for a modifier name ("option" → left and right Option).
    static func keyCodes(forModifierName name: String) -> Set<UInt16> {
        switch name.lowercased() {
        case "option", "alt": [0x3A, 0x3D]
        case "control", "ctrl": [0x3B, 0x3E]
        case "shift": [0x38, 0x3C]
        case "command", "cmd": [0x37, 0x36]
        default: MacKeyCode.code(named: name).map { [$0] } ?? []
        }
    }

    /// Web-based interfaces receive the original pointer stream while gameplay keeps its mode.
    public private(set) var nativeInterfaceActive = false
    private var nativeInterfaceRequested = false
    private var nativeButtons: Set<Int> = []
    public var mode: ControlMode {
        nativeInterfaceActive && modes.mode != .editor ? .textInput : modes.mode
    }

    public func setNativeInterfaceActive(_ active: Bool) {
        nativeInterfaceRequested = active
        // A web view can disappear on mouse-down. Its entire drag and release still belong
        // to UIKit, even if the game has already resumed drawing behind it.
        guard active || nativeButtons.isEmpty else { return }
        guard nativeInterfaceActive != active else { return }
        nativeInterfaceActive = active
        releaseInputs()
        onMappedModeChanged?()
        lastMouseConsumed = false
        updateCursorCapture()
    }

    /// Applies the starting mode's cursor state.
    public func start() {
        guard !started else { return }
        started = true
        // ControlsModule constructs the router before registering keymap actions.
        apply(modes.activate(usesMouse: capturesMouseView))
        updateCursorCapture()
    }

    /// A complete map replacement is distinct from a layer transition or a resize:
    /// release old contacts, chords and layer holds before new handlers are registered.
    func prepareForKeymapChange() { releaseInputs() }

    public func keymapRebuilt(_ map: KeymappingData? = nil) {
        if let map {
            heldLayers.reset()
            controlMap = map
            bindingGraph = ControlBindingGraph(map)
        }
        refreshControlPlan()
    }

    private func refreshControlPlan(preserveMode: Bool = false) {
        if let controlMap {
            controlPlan = AdaptiveControlPlan.resolve(controlMap, bundleIdentifier: bundleIdentifier,
                nativeController: settings.playMode == .virtualController,
                hybridController: settings.playMode == .hybrid, mouseGyro: settings.gyro.source == .mouse,
                activeLayer: dispatcher.activeLayer, bindingGraph: bindingGraph, interactionStyle: settings.interactionStyle)
        }
        apply(modes.keymapChanged(usesMouse: preserveMode ? modes.keymapUsesMouse : capturesMouseView,
                                  menuKeys: controlPlan?.menuKeys, preserveMode: preserveMode))
        if started { updateCursorCapture() }
    }

    /// The persistent view's policy is separate from whichever gameplay layer a key holds.
    /// This also keeps a layer-only camera available without requiring its layer key to stay down.
    private var capturesMouseView: Bool {
        guard let controlMap else { return dispatcher.usesMouse }
        return AdaptiveControlPlan.resolve(controlMap, bundleIdentifier: bundleIdentifier,
            nativeController: settings.playMode == .virtualController,
            hybridController: settings.playMode == .hybrid, mouseGyro: settings.gyro.source == .mouse,
            activeLayer: dispatcher.mouseViewLayer ?? 0, bindingGraph: bindingGraph,
            interactionStyle: settings.interactionStyle).capturesMouse
    }

    /// Explicit recovery from a menu dismissed by touch, with no held inputs left behind.
    @discardableResult public func resumeGameplay() -> Bool {
        guard !nativeInterfaceActive, mode != .editor, mode != .textInput else { return false }
        releaseInputs()
        apply(modes.resumeGameplay())
        updateCursorCapture()
        return mode == .camera
    }

    /// Old queued pointer deltas and pinch origins must not cross a viewport resize.
    /// Keyboard/button ownership remains intact.
    public func viewportChanged() {
        pendingMouse = .zero
        pendingMouseArrival = nil
        _ = rawMouse?.take()
        gestures?.cancel()
    }

    // MARK: Mode changes

    private func apply(_ transition: ModeTransition?) {
        guard let transition else { return }
        switch transition.release {
        case .all:
            // Also the layer, walk and gyro keys, whose releases would not arrive either.
            releaseInputs()
        case .nonButtons:
            dispatcher.invalidateNonButtons()
            gestures?.cancel()
            fakeMouse.release()
            pendingMouse = .zero
            pendingMouseArrival = nil
            _ = rawMouse?.take()
        case .none:
            break
        }
        onMappedModeChanged?()
        if transition.cursorShown || transition.cursorHidden {
            updateCursorCapture()
        }
    }

    /// Opens or closes the keymap editor: all touches are lifted and the cursor is shown.
    public func setEditorOpen(_ open: Bool) { apply(modes.editorToggled(open: open)) }

    /// The game lost focus (⌘-Tab, a click on another app). Key releases now go to that app,
    /// so lift every touch and forget held keys; otherwise the character keeps walking.
    public func focusLost() {
        guard focused else { return }
        focused = false
        edgeLockToggled = false
        cursorKeyTap = false
        heldCursorKeys.removeAll()
        nativeButtons.removeAll()
        setNativeInterfaceActive(nativeInterfaceRequested)
        updateCursorCapture()
        if !rawCalibration.isReady { rawCalibration = RawMouseCalibration() }
        releaseInputs()
    }

    private func releaseInputs() {
        cameraMouseButtons.removeAll()
        middleClickToggledCursor = false
        // The cursor key's tap survives this (2026-11-28 bug: a web view or text field flickering mid-tap, or a
        // keymap rebuild, reset it, so a tap of Alt sometimes did nothing and only a middle click switched back to
        // the camera). Its release still arrives here; only losing focus forgets it (`focusLost`).
        dispatcher.invalidateAll()
        gestures?.cancel()
        heldLayers.reset()
        dispatcher.setActiveLayer(0)
        virtualController?.setWalking(false)
        virtualController?.releaseAll()
        fakeMouse.release()
        pendingMouse = .zero
        pendingMouseArrival = nil
        _ = rawMouse?.take()
        cursorEventsWithoutRaw = 0
        ctrlModifiedKeys.removeAll()
        heldWalkKeys.removeAll()
        mappedKeys.removeAll()
        if !gyroKeys.isEmpty {
            gyroKeys.removeAll()
            mulg_motion_set_steady_rate(0, 0, 0)
        }
        // Losing focus/text/editor ownership also resets the active layer's policy.
        refreshControlPlan()
    }

    /// The game is in front again. A hold-mode cursor key released in another app never sent its
    /// release here, so the cursor would stay shown until the key was pressed again.
    public func focusGained() {
        guard !stopped, !focused else { return }
        _ = rawMouse?.take()
        focused = true
        if let transition = modes.cursorKeyReleased() { apply(transition) }
        else { updateCursorCapture() }
    }

    /// Closing is terminal: queued focus/input callbacks must not restart the mapper.
    func stop() {
        guard !stopped else { return }
        stopped = true
        if focused { focusLost() } else { releaseInputs() }
        rawMouse = nil
    }

    private func updateCursorCapture() {
        let hidden = focused && mode.hidesCursor
        environment.setCursorHidden(hidden)
        reportEdgeLock()
        if environment.isFullscreen || !hidden { environment.setMenuBarVisible(!hidden) }
        events.publish(CursorVisibilityChanged(visible: !hidden))
    }

    /// The window-edge lock the player switched with Alt or a middle click while mouse look stays on
    /// (`cursorKeySwitchesCamera` off). Cleared when the game loses focus.
    private var edgeLockToggled = false

    /// Alt and the middle button do the same thing. With `cursorKeySwitchesCamera` off they never touch
    /// mouse look (2026-11-28 user request): they only switch the window-edge lock.
    private func cursorToggle() {
        if settings.cursorKeySwitchesCamera {
            if let transition = modes.cursorClickToggled() { apply(transition) }
        } else {
            edgeLockToggled.toggle()
            reportEdgeLock()
        }
    }

    private func reportEdgeLock() {
        let shown = focused && !mode.hidesCursor
        let released = settings.cursorKeySwitchesCamera ? modes.cursorShownByPlayer : edgeLockToggled
        environment.setCursorReleasedByPlayer(shown && released)
    }

    public func textInputBegan() { apply(modes.textInputBegan()) }
    public func textInputEnded() { apply(modes.textInputEnded()) }

    // MARK: Keys

    /// Key presses and releases (not modifiers). Returns true when consumed.
    public func key(code: UInt16, pressed: Bool, isRepeat: Bool, flags: UInt) -> Bool {
        guard !stopped else { return false }
        let arrival = mach_absolute_time()
        mulg_touch_set_input_timestamp(measureLatency ? arrival : 0)
        defer { mulg_touch_set_input_timestamp(0) }
        let modifiers = ModifierSet(appKitFlags: flags)
        // Gameplay keys and their repeats may be held alongside Option. Only a system
        // shortcut cancels the cursor toggle; casting or clicking must not cancel it.
        if pressed && modifiers.contains(.command) { cursorKeyTap = false }
        if hotkeys.handle(keyCode: code, modifiers: modifiers, isDown: pressed, isRepeat: isRepeat) {
            return true
        }
        if pressed, modifiers.contains(.command) {
            // Menu shortcuts (⌘Q, ⌘W, …) belong to the app. Releases still go through, so a
            // key held before ⌘ was pressed lifts its touch instead of sticking.
            return false
        }
        switch mode {
        case .editor:
            // The editor's text field (naming a profile) types like any text field.
            if editor?.capturesText == true { return false }
            // Every key goes to the editor; the game gets nothing while it is open.
            if pressed, !isRepeat, let editor {
                _ = editor.editorKey(code: code, ctrlModified: modifiers.contains(.control))
            }
            return true
        case .textInput:
            return false // Composition, including repeated Return, belongs to the editor.
        case .off:
            // Upstream's transparent adapter: only a repeated Return is eaten.
            return isRepeat && code == 0x24
        case .camera, .cursor:
            break
        }
        if isRepeat {
            // Games expect one press and one release, not key repeats.
            return mappedKeys.contains(code)
        }
        if pressed { gameplayKeyPresses += 1 }
        let consumed = mappedKey(code: code, pressed: pressed, ctrlModified: modifiers.contains(.control))
        if pressed, consumed { mappedKeys.insert(code) }
        if !pressed { mappedKeys.remove(code) }
        // An unmapped Option chord belongs to native shortcuts. Mapped skills keep
        // the cursor-key tap pending, just like ordinary gameplay clicks.
        if pressed, modifiers.contains(.option), !consumed { cursorKeyTap = false }
        record(arrival: arrival, consumed: consumed)
        return consumed
    }

    private func mappedKey(code: UInt16, pressed: Bool, ctrlModified: Bool) -> Bool {
        let baseName = KeymapKeyNames.name(forVirtualKeyCode: code) ?? "Btn"
        // Keys never change the mode: only the cursor key and the middle button do.
        let wasInMenu = modes.isMenuOpen

        if layerKey(baseName, pressed: pressed) {
            return true
        }

        if settings.gyro.source == .keys, gyroKey(code: code, pressed: pressed) {
            return true
        }

        if settings.playMode != .touch, let controller = virtualController,
           let keymapCode = KeymapKeyNames.keymapCode(forVirtualKeyCode: code),
           controller.key(code: keymapCode, pressed: pressed, inMenu: wasInMenu) {
            return true
        }

        // Native controller mode must not fire a second, unrelated touchscreen action.
        // Hybrid explicitly opts into those extra HUD mappings.
        if settings.playMode == .virtualController { return false }

        // Upstream: Control+key is its own mapping ("⌃W"); a key pressed with Control is
        // released as "⌃W" too, even if Control was let go first.
        var name = baseName
        if ctrlModified && pressed && dispatcher.hasMapping(for: "⌃" + baseName) {
            name = "⌃" + name
            ctrlModifiedKeys.append(code)
        } else if !pressed, let index = ctrlModifiedKeys.firstIndex(of: code) {
            name = "⌃" + name
            ctrlModifiedKeys.remove(at: index)
        }
        return dispatcher.dispatch(key: name, pressed: pressed)
    }

    /// A layer's hold key (§14.5): pressing it switches to the layer, releasing it returns to
    /// the base keymap. Returns true when `name` is a layer key.
    private func layerKey(_ name: String, pressed: Bool, source: ControlInputSource = .keyboard) -> Bool {
        guard let layer = dispatcher.layer(heldBy: name) else { return false }
        let previous = dispatcher.activeLayer
        heldLayers.set(layer, pressed: pressed, source: source)
        dispatcher.setActiveLayer(heldLayers.activeLayer)
        if previous != dispatcher.activeLayer {
            onLayerChanged?(dispatcher.activeLayer)
            refreshControlPlan(preserveMode: true)
        }
        return true
    }

    /// Real controller buttons use the same layer rules as keyboard and mouse.
    /// Native-controller mode keeps the game's physical device stream untouched.
    func controllerButton(_ name: String, pressed: Bool) -> Bool {
        guard focused, !nativeInterfaceActive, mode == .camera || mode == .cursor else { return false }
        if layerKey(name, pressed: pressed, source: .controller) { return true }
        guard settings.playMode != .virtualController, touchMappingAvailable else { return false }
        return dispatcher.dispatch(key: name, pressed: pressed, source: .controller)
    }

    /// Arrow keys and [ ] rotate the virtual gyro while held.
    private func gyroKey(code: UInt16, pressed: Bool) -> Bool {
        switch code {
        case 0x7B, 0x7C, 0x7E, 0x7D, 0x21, 0x1E: break
        default: return false
        }
        let changed = pressed ? gyroKeys.insert(code).inserted : gyroKeys.remove(code) != nil
        guard changed else { return true }
        updateGyroRate()
        return true
    }

    private func updateGyroRate() {
        func axis(_ positive: UInt16, _ negative: UInt16) -> Int {
            (gyroKeys.contains(positive) ? 1 : 0) - (gyroKeys.contains(negative) ? 1 : 0)
        }
        let rate = GyroMapping.steadyRate(yawDirection: axis(0x7C, 0x7B), pitchDirection: axis(0x7D, 0x7E),
                                          rollDirection: axis(0x1E, 0x21), settings: settings.gyro)
        mulg_motion_set_steady_rate(rate.x, rate.y, rate.z)
    }

    /// Modifier keys pressed or released.
    public func modifier(code: UInt16, pressed: Bool, flags: UInt) -> Bool {
        guard !stopped else { return false }
        if cursorKeyCodes.contains(code) {
            // A tap of the cursor key toggles the cursor like a middle click (2026-10-10, user request): press
            // and release with nothing else between shows it and keeps it; the next tap returns to the camera.
            // The held keys are tracked in every mode, so a release during text input or the editor cannot
            // leave a key "held" and swallow the next taps.
            let gameplay = mode == .camera || mode == .cursor || mode == .off
            if pressed {
                if heldCursorKeys.isEmpty { cursorKeyTap = gameplay }
                heldCursorKeys.insert(code)
            } else {
                heldCursorKeys.remove(code)
            }
            if !pressed, heldCursorKeys.isEmpty, cursorKeyTap {
                cursorKeyTap = false
                if gameplay { cursorToggle() }
            }
            if gameplay { return false } // Let the system see the modifier too, as upstream did.
        }
        if mode == .textInput { return false }
        if mode == .editor {
            if editor?.capturesText == true { return false }
            // Shift can be bound in the editor; the editor refuses the other modifiers.
            if pressed, let editor {
                _ = editor.editorKey(code: code, ctrlModified: false)
            }
            return false
        }
        if pressed && (code == 0x37 || code == 0x36) { cursorKeyTap = false }
        if walkKeyCodes.contains(code) {
            if pressed { heldWalkKeys.insert(code) } else { heldWalkKeys.remove(code) }
            let walking = !heldWalkKeys.isEmpty
            dispatcher.setWalking(walking)
            if let controller = virtualController, settings.playMode != .touch { controller.setWalking(walking) }
        }
        guard mode == .camera || mode == .cursor else { return false }
        // Other modifiers are ordinary keys in keymaps ("Lshft", "LCtrl").
        if code == 0x3B || code == 0x3E, !pressed, !ModifierSet(appKitFlags: flags).contains(.control) {
            // Control released: release every key that was pressed with it. A copy, because a key
            // that became a layer or controller key since (keymap switched) returns before it
            // leaves the list, and looping on the list itself would never end.
            for key in ctrlModifiedKeys {
                _ = mappedKey(code: key, pressed: false, ctrlModified: true)
            }
            ctrlModifiedKeys.removeAll()
        }
        return mappedKey(code: code, pressed: pressed, ctrlModified: false)
    }

    // MARK: Mouse

    public func mouseMoved(dx: CGFloat, dy: CGFloat) -> Bool {
        guard !stopped, focused, !nativeInterfaceActive || mode == .editor else { return false }
        guard dx.isFinite, dy.isFinite,
              (pendingMouse.dx + dx).isFinite, (pendingMouse.dy + dy).isFinite else { return false }
        if rawMouse != nil, mode == .camera {
            // The same movement also arrives raw from GCMouse. If it stops arriving (the game set
            // its own handler), the cursor's movement takes over again. Until GCMouse is
            // calibrated against the cursor, the cursor drives the camera.
            cursorEventsWithoutRaw += 1
            if cursorEventsWithoutRaw >= 50 {
                rawMouse = nil
            } else if rawCalibration.isReady {
                return lastMouseConsumed
            } else {
                rawCalibration.cursorMoved(dx: dx, dy: dy)
            }
        }
        pendingMouse.dx += dx
        pendingMouse.dy += dy
        if pendingMouseArrival == nil { pendingMouseArrival = mach_absolute_time() }
        return sendMouse()
    }

    /// Sends the waiting movement, at most `maximumMouseRate` times a second.
    private func sendMouse() -> Bool {
        let now = mach_absolute_time()
        if Self.nanoseconds(from: lastMouseDispatch, to: now) < Self.mouseInterval {
            scheduleMouseFlush()
            return lastMouseConsumed
        }
        return flushMouse(at: now)
    }

    private static let mouseInterval = UInt64(1e9 / maximumMouseRate)

    private func flushMouse(at now: UInt64) -> Bool {
        lastMouseDispatch = now
        let movement = pendingMouse
        guard movement != .zero else { return lastMouseConsumed }
        let arrival = pendingMouseArrival ?? now
        pendingMouse = .zero
        pendingMouseArrival = nil
        mulg_touch_set_input_timestamp(measureLatency ? arrival : 0)
        defer { mulg_touch_set_input_timestamp(0) }
        lastMouseConsumed = handleMouseMovement(dx: movement.dx, dy: movement.dy)
        record(arrival: arrival, consumed: lastMouseConsumed)
        return lastMouseConsumed
    }

    /// The end of a flick used to wait in `pendingMouse` until the mouse moved again, so the camera
    /// stopped short and then jumped. Send it once the interval is up.
    private func scheduleMouseFlush() {
        guard !mouseFlushScheduled else { return }
        mouseFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1 / Self.maximumMouseRate) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mouseFlushScheduled = false
                guard self.pendingMouse != .zero else { return }
                let now = mach_absolute_time()
                if Self.nanoseconds(from: self.lastMouseDispatch, to: now) < Self.mouseInterval {
                    self.scheduleMouseFlush()
                } else {
                    _ = self.flushMouse(at: now)
                }
            }
        }
    }

    /// Main thread, just before a display-link frame starts: movement still waiting is sent now,
    /// so the frame reads the newest position.
    public func frameStarts() {
        guard !stopped else { return }
        virtualController?.frameStarts()
        takeRawMouse()
        if pendingMouse != .zero {
            _ = flushMouse(at: mach_absolute_time())
        }
        mulg_touch_flush()
    }

    /// Main thread, after GCMouse delivered movement.
    func rawMouseMoved() {
        guard !stopped else { return }
        takeRawMouse()
        if pendingMouse != .zero {
            _ = sendMouse()
        }
    }

    /// Adds the GCMouse movement collected so far to the waiting movement, in camera mode only:
    /// the cursor mode follows the cursor itself.
    private func takeRawMouse() {
        guard let rawMouse else { return }
        let sample = rawMouse.takeSample()
        let movement = sample.movement
        guard focused, movement != .zero else { return }
        cursorEventsWithoutRaw = 0
        if mode == .camera, let adjusted = rawCalibration.adjust(movement) {
            if let arrival = sample.arrival {
                pendingMouseArrival = min(pendingMouseArrival ?? arrival, arrival)
            }
            pendingMouse.dx += adjusted.dx
            pendingMouse.dy += adjusted.dy
        }
    }

    private func handleMouseMovement(dx: CGFloat, dy: CGFloat) -> Bool {
        switch mode {
        case .camera:
            if settings.gyro.source == .mouse {
                let rotation = GyroMapping.rotation(mouseDX: Double(dx), mouseDY: Double(dy), settings: settings.gyro)
                mulg_motion_add_rotation(rotation.x, rotation.y, rotation.z)
                return true
            }
            if settings.playMode == .virtualController, let controller = virtualController {
                controller.mouseMoved(dx: Double(dx), dy: Double(dy))
                return true
            }
            return dispatcher.dispatchMouseView(x: dx * sensitivity, y: -dy * sensitivity)
        case .cursor:
            if dispatcher.motionPriority(for: KeymapNames.mouseMove) == .draggable {
                // A draggable button is held: it follows the mouse.
                return dispatcher.dispatch(key: KeymapNames.mouseMove, x: dx, y: -dy)
            }
            if fakeMouse.isPressed, let point = environment.cursorPoint() {
                fakeMouse.drag(to: point)
                return true
            }
            return false
        case .off, .textInput, .editor:
            return false
        }
    }

    public func mouseButton(_ button: Int, pressed: Bool) -> Bool {
        guard !stopped else { return false }
        if pressed && button == 2 { cursorKeyTap = false }
        if nativeInterfaceActive && mode != .editor {
            if pressed { nativeButtons.insert(button) }
            else {
                nativeButtons.remove(button)
                if nativeButtons.isEmpty { setNativeInterfaceActive(nativeInterfaceRequested) }
            }
            return false
        }
        // Middle click is reserved for the player's cursor switch during gameplay, regardless
        // of skill/button bindings. The editor still receives it for assigning ordinary controls.
        if button == 2 {
            if !pressed, middleClickToggledCursor {
                middleClickToggledCursor = false
                return true
            }
            if pressed, mode == .camera || mode == .cursor || mode == .off {
                if settings.cursorKeySwitchesCamera {
                    if let transition = modes.cursorClickToggled() {
                        middleClickToggledCursor = true
                        apply(transition)
                        return true
                    }
                } else {
                    // Never reaches the game either, so a middle click cannot disturb mouse look.
                    middleClickToggledCursor = true
                    cursorToggle()
                    return true
                }
            }
        }
        let arrival = mach_absolute_time()
        mulg_touch_set_input_timestamp(measureLatency ? arrival : 0)
        defer { mulg_touch_set_input_timestamp(0) }
        if !pressed && cameraMouseButtons.remove(button) != nil {
            let name = KeymapKeyNames.name(forMouseButton: button)
            let consumed: Bool
            if layerKey(name, pressed: false, source: .mouse) {
                consumed = true
            } else if settings.playMode != .touch, let controller = virtualController,
                      let code = KeymapKeyNames.code(forMouseButton: button), controller.key(code: code, pressed: false) {
                consumed = true
            } else if settings.playMode == .virtualController {
                consumed = false
            } else {
                consumed = dispatcher.dispatch(key: name, pressed: false, source: .mouse)
            }
            record(arrival: arrival, consumed: consumed)
            return consumed
        }
        if pressed, mode == .camera { gameplayMousePresses += 1 }
        // In cursor mode the left button clicks the game's interface, so it never switches layers.
        if mode == .camera || (mode == .cursor && button != 0),
           layerKey(KeymapKeyNames.name(forMouseButton: button), pressed: pressed, source: .mouse) {
            if pressed && mode == .camera { cameraMouseButtons.insert(button) }
            return true
        }
        let consumed: Bool
        switch mode {
        case .camera:
            if settings.playMode != .touch, let controller = virtualController,
               let code = KeymapKeyNames.code(forMouseButton: button), controller.key(code: code, pressed: pressed) {
                consumed = true
            } else if settings.playMode == .virtualController {
                // Match the keyboard path: only hybrid mode opts into extra
                // gameplay touches when a native controller binding is absent.
                consumed = false
            } else {
                consumed = dispatcher.dispatch(key: KeymapKeyNames.name(forMouseButton: button), pressed: pressed, source: .mouse)
            }
            if pressed && consumed { cameraMouseButtons.insert(button) }
        case .cursor:
            if button == 0 && touchMappingAvailable {
                // Clicks become taps at the cursor.
                if pressed {
                    guard let point = environment.cursorPoint() else { return false }
                    fakeMouse.press(at: point)
                } else {
                    fakeMouse.release(at: environment.cursorPoint())
                }
                consumed = true
            } else if settings.playMode == .virtualController {
                consumed = false
            } else {
                consumed = dispatcher.dispatch(key: KeymapKeyNames.name(forMouseButton: button), pressed: pressed, source: .mouse)
            }
        case .editor:
            // Left clicks reach the editor through UIKit; other buttons are bound to the selection.
            guard button != 0 else { return false }
            if pressed { _ = editor?.editorMouseButton(button) }
            return true
        case .off, .textInput:
            consumed = false
        }
        record(arrival: arrival, consumed: consumed)
        return consumed
    }

    /// The cursor key is down and nothing else was pressed since: its release is a tap.
    private var cursorKeyTap = false

    /// The middle click that toggled the cursor; its release is swallowed too.
    private var middleClickToggledCursor = false

    public func scroll(dx: CGFloat, dy: CGFloat) -> Bool {
        guard !stopped else { return false }
        guard enableScrollWheel, touchMappingAvailable else { return false }
        switch mode {
        case .camera:
            // Only a mapped scroll zoom takes the wheel; without one the game gets it (it was always
            // swallowed, so games that zoom with the wheel themselves never saw it in play).
            let zoomed = dispatcher.dispatch(key: KeymapNames.scrollWheelScale, x: dx, y: dy)
            // Pinching in (dy > 0) moves the camera away (PinchZoom). Camera reach follows the zoom either way.
            if dy != 0 { events.publish(PlayerZoomed(outward: dy > 0)) }
            return zoomed
        case .cursor:
            // Upstream let the scroll through as well as dragging.
            _ = dispatcher.dispatch(key: KeymapNames.scrollWheelDrag, x: dx, y: dy)
            return false
        case .off, .textInput, .editor:
            return false
        }
    }

    // MARK: Trackpad

    public func magnify(_ amount: CGFloat, phase: Int) -> Bool {
        guard !stopped else { return false }
        guard settings.trackpadGestures, let gestures, mode == .cursor || mode == .camera else { return false }
        gestures.magnify(by: amount, phase: phase, at: environment.cursorPoint())
        return true
    }

    public func rotate(_ degrees: CGFloat, phase: Int) -> Bool {
        guard !stopped else { return false }
        guard settings.trackpadGestures, let gestures, mode == .cursor || mode == .camera else { return false }
        gestures.rotate(by: degrees, phase: phase, at: environment.cursorPoint())
        return true
    }

    // MARK: Latency (§6.1)

    private func record(arrival: UInt64, consumed: Bool) {
        guard measureLatency, consumed, !mulg_touch_input_was_queued() else { return }
        events.publish(InputDelivered(arrival: arrival, injected: mach_absolute_time()))
    }

    // Read once: this runs for every mouse event.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nanoseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        guard end > start else { return 0 }
        return (end - start) * UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
    }
}

/// Unaccelerated mouse movement from GCMouse (controls.rawMouse). GameController calls its
/// handler on the device owner's queue. Thread-safe collection preserves that queue for the
/// game's native button/scroll callbacks and batches movement before the next frame starts.
final class RawMouse: Sendable {
    private struct Pending {
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var flushScheduled = false
        var arrival: UInt64?
    }

    private let pending = Mutex(Pending())

    /// Any thread. Returns true when the main thread should be asked to flush.
    func add(dx: CGFloat, dy: CGFloat) -> Bool {
        guard dx.isFinite, dy.isFinite else { return false }
        return pending.withLock { pending in
            let x = pending.dx + dx, y = pending.dy + dy
            guard x.isFinite, y.isFinite else { return false }
            pending.dx = x
            pending.dy = y
            if pending.arrival == nil { pending.arrival = mach_absolute_time() }
            defer { pending.flushScheduled = true }
            return !pending.flushScheduled
        }
    }

    func take() -> CGVector {
        takeSample().movement
    }

    func takeSample() -> (movement: CGVector, arrival: UInt64?) {
        pending.withLock { pending in
            defer { pending = Pending() }
            return (CGVector(dx: pending.dx, dy: pending.dy), pending.arrival)
        }
    }
}

/// How GCMouse movement maps to the cursor's (controls.rawMouse). The direction of each axis and
/// the units are not known for every mouse and macOS build, so they are learned while both arrive:
/// the cursor drives the camera until each axis has moved `enough` points, then GCMouse does,
/// corrected. One scale for both axes keeps the camera sensitivity setting meaningful.
struct RawMouseCalibration {
    static let enough: CGFloat = 400

    private var cursor = CGVector.zero       // since the last GCMouse movement
    private var agreement = CGVector.zero    // sum of cursor × GCMouse, per axis
    private var cursorTotal = CGVector.zero
    private var rawTotal = CGVector.zero
    private(set) var correction: CGVector?

    var isReady: Bool {
        correction != nil
    }

    mutating func cursorMoved(dx: CGFloat, dy: CGFloat) {
        cursor.dx += dx
        cursor.dy += dy
    }

    /// The GCMouse movement in cursor points, or nil while still learning.
    mutating func adjust(_ raw: CGVector) -> CGVector? {
        if let correction {
            return CGVector(dx: raw.dx * correction.dx, dy: raw.dy * correction.dy)
        }
        agreement.dx += cursor.dx * raw.dx
        agreement.dy += cursor.dy * raw.dy
        cursorTotal.dx += abs(cursor.dx)
        cursorTotal.dy += abs(cursor.dy)
        rawTotal.dx += abs(raw.dx)
        rawTotal.dy += abs(raw.dy)
        cursor = .zero
        guard cursorTotal.dx >= Self.enough, cursorTotal.dy >= Self.enough,
              rawTotal.dx > 0, rawTotal.dy > 0 else { return nil }
        // The cursor is accelerated and GCMouse is not, so this is the average acceleration.
        let scale = min(max((cursorTotal.dx + cursorTotal.dy) / (rawTotal.dx + rawTotal.dy), 0.1), 10)
        correction = CGVector(dx: agreement.dx < 0 ? -scale : scale, dy: agreement.dy < 0 ? -scale : scale)
        return nil
    }
}
