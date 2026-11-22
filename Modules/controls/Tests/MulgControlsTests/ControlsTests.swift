import CoreGraphics
import Foundation
import Testing
import MulgContracts
import MulgControlsHooks
import MulgEngine
import GameController
@testable import MulgControls

private final class EditableResponderFixture: NSObject { @objc func isEditable() -> Bool { true } }
private final class ChangedEditableFixture: NSObject { @objc func isEditable() -> Int { 1 } }

@Suite("Editable responder ABI")
struct EditableResponderTests {
    @Test func recognizesEditorsAndRejectsChangedSignatures() {
        #expect(mulg_controls_responder_is_editable(EditableResponderFixture()))
        #expect(!mulg_controls_responder_is_editable(ChangedEditableFixture()))
        #expect(!mulg_controls_responder_is_editable(NSObject()))
    }
}

@Suite("Controller callback snapshots") @MainActor
struct ControllerSnapshotTests {
    @Test func editorAndTextInputSuspendGameplayAndInvalidateQueuedSamples() async throws {
        let dispatcher = ActionDispatcher()
        var moves = 0, buttons: [Bool] = [], bindings: [String] = []
        dispatcher.register(key: "Right Thumbstick", priority: .camera) { _, _ in moves += 1 }
        dispatcher.register(key: "Button A") { buttons.append($0) }
        let input = ControllerInput(dispatcher: dispatcher, virtualController: nil)
        let controller = GCController.withExtendedGamepad(); input.attach(controller)
        let id = ObjectIdentifier(controller), old = try #require(input.token(for: controller))
        input.changed(.button("Button A", true), controller: id, generation: old)
        input.changed(.stick("Right Thumbstick", 1, 0), controller: id, generation: old)
        input.editorSink = { bindings.append($0) }
        let editorToken = try #require(input.token(for: controller)), before = moves
        input.changed(.button("Button A", false), controller: id, generation: old)
        input.changed(.button("Button A", true), controller: id, generation: editorToken)
        try await Task.sleep(for: .milliseconds(40))
        #expect(moves == before && buttons == [true, false] && bindings == ["Button A"])
        input.editorSink = nil
        input.changed(.button("Button A", true), controller: id, generation: editorToken)
        #expect(buttons == [true, false])
        input.changed(.button("Button A", true), controller: id, generation: try #require(input.token(for: controller)))
        #expect(buttons == [true, false, true])
        input.setTextInputActive(true)
        #expect(input.token(for: controller) == nil && buttons == [true, false, true, false])
        input.focusLost(); input.setTextInputActive(false)
        #expect(input.token(for: controller) == nil)
        input.focusGained()
        #expect(input.token(for: controller) != nil)
        input.focusLost()
    }
    @Test func disconnectAndFocusEpochsRejectStaleSamplesWithoutReleasingOtherDevices() throws {
        let dispatcher = ActionDispatcher()
        var buttons: [Bool] = [], movement: [CGFloat] = []
        dispatcher.register(key: "Button A") { buttons.append($0) }
        dispatcher.register(key: "Left Thumbstick") { x, _ in movement.append(x) }
        let input = ControllerInput(dispatcher: dispatcher, virtualController: nil)
        let first = GCController.withExtendedGamepad(), second = GCController.withExtendedGamepad()
        input.attach(first); input.attach(second)
        let old = try #require(input.token(for: first)), other = try #require(input.token(for: second))
        let a = ObjectIdentifier(first), b = ObjectIdentifier(second)
        input.changed(.button("Button A", true), controller: a, generation: old)
        input.changed(.button("Button A", true), controller: b, generation: other)
        input.changed(.stick("Left Thumbstick", 0.4, 0), controller: a, generation: old)
        input.changed(.stick("Left Thumbstick", 0.8, 0), controller: b, generation: other)
        input.disconnect(second)
        #expect(buttons == [true], "first controller still holds the shared button")
        #expect(abs((movement.last ?? 0) - 0.4) < 0.001, "restore the other controller's held stick")
        input.changed(.button("Button A", false), controller: b, generation: other)
        #expect(buttons == [true])
        input.disconnect(first)
        #expect(buttons == [true, false] && movement.last == 0)
        input.attach(first)
        let reconnected = try #require(input.token(for: first))
        #expect(reconnected != old)
        input.changed(.button("Button A", true), controller: a, generation: old)
        #expect(buttons == [true, false])
        input.changed(.button("Button A", true), controller: a, generation: reconnected)
        input.focusLost(); input.focusGained()
        input.changed(.button("Button A", true), controller: a, generation: reconnected)
        #expect(buttons == [true, false, true, false])
        input.changed(.button("Button A", true), controller: a, generation: try #require(input.token(for: first)))
        #expect(buttons.last == true)
        input.focusLost()
    }

    @Test func liveStickCurveReshapesHeldInputWithoutReleasingButtonsOrResumingSuspendedInput() throws {
        let dispatcher = ActionDispatcher()
        var movement: [CGFloat] = [], buttons: [Bool] = []
        dispatcher.register(key: "Left Thumbstick") { x, _ in movement.append(x) }
        dispatcher.register(key: "Button A") { buttons.append($0) }
        let input = ControllerInput(dispatcher: dispatcher, virtualController: nil)
        let controller = GCController.withExtendedGamepad()
        input.attach(controller)
        let identity = ObjectIdentifier(controller), old = try #require(input.token(for: controller))
        input.changed(.button("Button A", true), controller: identity, generation: old)
        input.changed(.stick("Left Thumbstick", 0.2, 0), controller: identity, generation: old)
        #expect(abs((movement.last ?? 0) - 0.2) < 0.001)
        var settings = ControllerStickSettings()
        settings.deadzone = 0.3
        input.updateStickSettings(settings)
        #expect(movement.last == 0)
        #expect(buttons == [true] && input.token(for: controller) == old)
        let current = try #require(input.token(for: controller))
        input.changed(.stick("Left Thumbstick", 0.2, 0), controller: identity, generation: current)
        #expect(movement.last == 0)
        input.changed(.stick("Left Thumbstick", 0.65, 0), controller: identity, generation: current)
        #expect(abs((movement.last ?? 0) - 0.5) < 0.001)
        input.setTextInputActive(true)
        settings.exponent = 2
        input.updateStickSettings(settings)
        #expect(input.token(for: controller) == nil && buttons == [true, false])
        input.focusLost()
    }

    @Test("A held camera stick moves once per frame start, scaled by the time between frames")
    func cameraStepsOnFrameStarts() async throws {
        let dispatcher = ActionDispatcher()
        var steps: [CGFloat] = []
        _ = dispatcher.register(key: "Right Thumbstick", priority: .camera) { x, _ in steps.append(x) }
        let input = ControllerInput(dispatcher: dispatcher, virtualController: nil)
        let controller = GCController.withExtendedGamepad()
        input.attach(controller)
        let identity = ObjectIdentifier(controller), token = try #require(input.token(for: controller))
        input.changed(.stick("Right Thumbstick", 1, 0), controller: identity, generation: token)
        let before = steps.count
        input.frameStarted()
        let clock = ContinuousClock(), sleptFrom = clock.now
        try await Task.sleep(for: .milliseconds(17))
        input.frameStarted()
        let slept = sleptFrom.duration(to: clock.now)
        #expect(steps.count >= before + 2)
        // One 60 Hz step's worth (6) scaled by the time that really passed: a busy Mac sleeps longer. Past
        // 50 ms without frames the fallback loop steps in between (by design), so only a short sleep is exact.
        if slept < .milliseconds(45) {
            #expect(abs((steps.last ?? 0) - 6 * ControllerInput.stepScale(elapsed: slept)) < 3)
        }
        // While frames arrive (within 50 ms of each other), the fallback loop adds nothing between them.
        input.frameStarted()
        let count = steps.count, pauseFrom = clock.now
        try await Task.sleep(for: .milliseconds(30))
        if pauseFrom.duration(to: clock.now) < .milliseconds(45) { #expect(steps.count == count) }
        input.focusLost()
    }

    @Test func capturesBothEdgesBeforeTheProfileChangesAgain() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        pad.buttonA.setValue(1)
        let press = try #require(ControllerInput.Sample.capture(pad.buttonA))
        pad.buttonA.setValue(0)
        let release = try #require(ControllerInput.Sample.capture(pad.buttonA))
        guard case .button(let pressName, let pressed) = press,
              case .button(let releaseName, let released) = release else {
            Issue.record("button snapshots expected"); return
        }
        #expect(pressName == releaseName && pressed && !released)
        pad.leftThumbstick.setValueForXAxis(0.75, yAxis: -0.5)
        let stick = try #require(ControllerInput.Sample.capture(pad.leftThumbstick))
        pad.leftThumbstick.setValueForXAxis(0, yAxis: 0)
        guard case .stick(_, let x, let y) = stick else { Issue.record("stick snapshot expected"); return }
        #expect(x == 0.75 && y == -0.5)
    }
}

// MARK: - Test doubles

@MainActor
/// ControlsModule resolves the control plan from the game's keymap, controller bindings included.
func genshinControllerMap() -> KeymappingData {
    var map = KeymappingData(bundleIdentifier: "com.miHoYo.GenshinImpact")
    map.mulgControllerBindings = GenshinDefaults.controllerBindings
    return map
}

/// Joystick contacts move only after UIKit delivered their neutral begin (and, for floating joysticks,
/// an activation delay), on a main-actor task. Tests wait for that move instead of expecting it at once.
extension RecordingInjector {
    @MainActor func settle(until count: Int, timeout: Duration = .seconds(1)) async {
        let clock = ContinuousClock(), deadline = clock.now + timeout
        while events.count < count, clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

final class RecordingInjector: TouchInjecting {
    struct Event: Equatable {
        let id: Int
        let point: CGPoint
        let phase: TouchPhase
    }

    var screenBounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
    private(set) var events: [Event] = []
    private var nextID = 0

    func touch(_ id: inout Int?, at point: CGPoint, phase: TouchPhase) {
        switch phase {
        case .began:
            guard id == nil else { return }
            id = nextID
            nextID += 1
        case .moved, .ended:
            guard id != nil else { return }
        }
        events.append(Event(id: id!, point: point, phase: phase))
        if phase == .ended { id = nil }
    }
}

// MARK: - Modes

@Suite("Hold-Option cursor (§14.2)")
struct HoldCursorTests {
    @Test("Hold mode starts in camera mode when the keymap uses the mouse")
    func startsInCamera() {
        let machine = ControlModeMachine(behaviour: .hold, pauseForTextInput: true, keymapUsesMouse: true)
        #expect(machine.mode == .camera)
    }

    @Test("Holding shows the cursor and releasing hides it, keeping held buttons")
    func holdAndRelease() {
        var machine = ControlModeMachine(behaviour: .hold, pauseForTextInput: true, keymapUsesMouse: true)
        let show = machine.cursorKeyPressed()
        #expect(machine.mode == .cursor)
        #expect(show?.cursorShown == true)
        #expect(show?.release == .nonButtons)
        let hide = machine.cursorKeyReleased()
        #expect(machine.mode == .camera)
        #expect(hide?.cursorHidden == true)
    }

    @Test("Only the cursor key and the middle button change the mode, never a menu key")
    func onlyCursorControlsChangeMode() {
        var machine = ControlModeMachine(behaviour: .hold, pauseForTextInput: true, keymapUsesMouse: true, menuKeys: ["M", "B"])
        #expect(machine.mode == .camera)
        _ = machine.cursorClickToggled()
        #expect(machine.mode == .cursor && machine.isMenuOpen)
        _ = machine.keymapChanged(usesMouse: true, menuKeys: ["M", "B"])
        #expect(machine.mode == .cursor, "A refresh keeps a cursor the player asked for")
        _ = machine.cursorClickToggled()
        #expect(machine.mode == .camera && !machine.isMenuOpen)
    }

    @Test("Text input pauses keymapping and returns to camera mode afterwards")
    func textInput() {
        var machine = ControlModeMachine(behaviour: .hold, pauseForTextInput: true, keymapUsesMouse: true)
        let pause = machine.textInputBegan()
        #expect(machine.mode == .textInput)
        #expect(pause?.release == .all)
        #expect(machine.cursorKeyPressed() == nil)
        _ = machine.textInputEnded()
        #expect(machine.mode == .camera)
    }
}

@Suite("Toggle mode (upstream behaviour)")
struct ToggleCursorTests {
    @Test("Toggle mode starts with the cursor and switches on each press")
    func toggle() {
        var machine = ControlModeMachine(behaviour: .toggle, pauseForTextInput: true, keymapUsesMouse: true)
        #expect(machine.mode == .cursor)
        _ = machine.cursorKeyPressed()
        #expect(machine.mode == .camera)
        _ = machine.cursorKeyReleased()
        #expect(machine.mode == .camera)
        _ = machine.cursorKeyPressed()
        #expect(machine.mode == .cursor)
    }

    @Test("Without text-input pausing, the idle mode is off, and stopping releases every touch")
    func offMode() {
        var machine = ControlModeMachine(behaviour: .toggle, pauseForTextInput: false, keymapUsesMouse: true)
        #expect(machine.mode == .off)
        _ = machine.cursorKeyPressed()
        #expect(machine.mode == .camera)
        let back = machine.cursorKeyPressed()
        #expect(machine.mode == .off)
        #expect(back?.release == .all)
    }
}

// MARK: - Maths

@Suite("Mouse to stick (§14.1)")
struct StickCurveTests {
    @Test("Movement pushes the stick, clamped to full tilt, and it returns to centre")
    func pushAndDecay() {
        var curve = StickCurve(settings: StickCurveSettings())
        curve.push(dx: 100, dy: 0)
        #expect(curve.x == 1)
        #expect(curve.y == 0)
        for _ in 0..<40 { curve.decay() }
        #expect(curve.isCentred)
    }

    @Test("Moving the mouse up pushes the stick up")
    func verticalDirection() {
        var curve = StickCurve(settings: StickCurveSettings())
        curve.push(dx: 0, dy: -5)
        #expect(curve.y > 0)
    }

    @Test("Tiny movements inside the dead zone are ignored")
    func deadzone() {
        var curve = StickCurve(settings: StickCurveSettings())
        curve.push(dx: 0.1, dy: 0)
        #expect(curve.isCentred)
    }
}

@Suite("Controller stick response (§13.2)")
struct StickResponseTests {
    @Test("Defaults pass through; the dead zone swallows drift and rescales the rest")
    func shape() {
        let raw = StickResponse.shape(x: 0.9, y: 0.9, settings: ControllerStickSettings())
        #expect(raw.x == 0.9 && raw.y == 0.9)
        var settings = ControllerStickSettings()
        settings.deadzone = 0.2
        let drift = StickResponse.shape(x: 0.1, y: 0.1, settings: settings)
        #expect(drift.x == 0 && drift.y == 0)
        let full = StickResponse.shape(x: 1, y: 0, settings: settings)
        #expect(abs(full.x - 1) < 0.0001 && full.y == 0)
        let half = StickResponse.shape(x: 0, y: -0.6, settings: settings)
        #expect(abs(half.y + 0.5) < 0.0001)
        settings.exponent = 2
        #expect(abs(StickResponse.shape(x: 0, y: -0.6, settings: settings).y + 0.25) < 0.0001)
    }
}

@Suite("Keys to the left stick")
struct KeyStickTests {
    @Test("Diagonals are not faster than straight lines, and walking halves the tilt")
    func diagonalAndWalk() {
        var stick = KeyStick()
        stick.set(.leftStickUp, pressed: true)
        stick.set(.leftStickRight, pressed: true)
        let value = stick.value
        #expect(abs((value.x * value.x + value.y * value.y).squareRoot() - 1) < 0.0001)
        stick.walking = true
        #expect(abs(stick.value.x - value.x / 2) < 0.0001)
    }
}

@Suite("Gyro mapping (§14.3)")
struct GyroMappingTests {
    @Test("Moving the mouse right turns right: negative about the upright device's X axis")
    func yaw() {
        let rotation = GyroMapping.rotation(mouseDX: 10, mouseDY: 0, settings: GyroSettings())
        #expect(rotation.x < 0)
        #expect(rotation.y == 0)
    }

    @Test("Invert pitch flips only the vertical axis")
    func invert() {
        var settings = GyroSettings()
        let normal = GyroMapping.rotation(mouseDX: 0, mouseDY: 10, settings: settings)
        settings.invertPitch = true
        let inverted = GyroMapping.rotation(mouseDX: 0, mouseDY: 10, settings: settings)
        #expect(normal.y == -inverted.y)
    }

    @Test("Held keys give a steady rate in radians per second")
    func keys() {
        var settings = GyroSettings()
        settings.keyRotationSpeed = 180
        let rate = GyroMapping.steadyRate(yawDirection: 1, pitchDirection: 0, rollDirection: 0, settings: settings)
        #expect(abs(rate.x + Double.pi) < 1e-9)
    }
}

/// The integrator is process-wide state, so these run one at a time.
@Suite("Virtual gyro integrator", .serialized)
struct MotionMathTests {
    @Test("At rest the virtual iPad is upright in landscape: gravity along -X, no rotation")
    func resting() {
        mulg_motion_set_steady_rate(0, 0, 0)
        mulg_motion_recenter()
        let sample = mulg_motion_step(0.01)
        #expect(abs(sample.gravityX + 1) < 1e-9)
        #expect(abs(sample.gravityY) < 1e-9)
        #expect(abs(sample.gravityZ) < 1e-9)
        #expect(sample.rateX == 0 && sample.rateY == 0 && sample.rateZ == 0)
    }

    @Test("A mouse rotation becomes a rate over the next step, then stops: no drift")
    func noDrift() {
        mulg_motion_recenter()
        mulg_motion_set_steady_rate(0, 0, 0)
        mulg_motion_add_rotation(0.1, 0, 0)
        let moving = mulg_motion_step(0.01)
        #expect(abs(moving.rateX - 10) < 1e-9)
        let still = mulg_motion_step(0.01)
        #expect(still.rateX == 0)
    }

    @Test("Gyro keys stop after one release and ignore a stale release after focus loss")
    @MainActor
    func gyroKeyBalance() {
        final class Environment: InputEnvironment {
            func cursorPoint() -> CGPoint? { nil }
            func setCursorHidden(_ hidden: Bool) {}
            var isFullscreen: Bool { false }
            func setMenuBarVisible(_ visible: Bool) {}
        }
        var settings = GameSettings()
        settings.mulg.controls.gyro.source = .keys
        let dispatcher = ActionDispatcher()
        dispatcher.register(key: KeymapNames.mouseMove) { _, _ in }
        let injector = RecordingInjector()
        let router = InputRouter(settings: settings, dispatcher: dispatcher, hotkeys: HotkeyCenter(),
                                 events: EventBus(), environment: Environment(),
                                 fakeMouse: FakeMouseAction(injector: injector), menuKeys: [])
        mulg_motion_set_steady_rate(0, 0, 0)
        mulg_motion_recenter()
        defer { mulg_motion_set_steady_rate(0, 0, 0) }
        #expect(router.key(code: 0x7B, pressed: true, isRepeat: false, flags: 0))
        #expect(router.key(code: 0x7B, pressed: true, isRepeat: false, flags: 0))
        #expect(mulg_motion_step(0.01).rateX != 0)
        #expect(router.key(code: 0x7B, pressed: false, isRepeat: false, flags: 0))
        #expect(mulg_motion_step(0.01).rateX == 0)
        router.focusLost()
        router.focusGained()
        #expect(router.key(code: 0x7B, pressed: false, isRepeat: false, flags: 0))
        #expect(mulg_motion_step(0.01).rateX == 0)
    }
}

@Suite("Cursor position")
struct CursorMappingTests {
    @Test("A point in the middle of the window maps to the middle of the game screen")
    func middle() throws {
        let point = try #require(CursorMapping.gamePoint(
            mouse: CGPoint(x: 500, y: 300), window: CGRect(x: 0, y: 0, width: 1000, height: 600),
            screen: CGSize(width: 2000, height: 1200), fullscreen: false, resizable: false))
        #expect(abs(point.x - 1000) < 0.001)
        #expect(abs(point.y - 600) < 0.001)
    }

    @Test("The title bar area above the game is not mapped")
    func titleBar() {
        let point = CursorMapping.gamePoint(
            mouse: CGPoint(x: 500, y: 650), window: CGRect(x: 0, y: 0, width: 1000, height: 600),
            screen: CGSize(width: 2000, height: 1200), fullscreen: false, resizable: false)
        #expect(point == nil)
    }

    @Test("Resizable windows keep a 10-point edge for resizing")
    func resizeEdge() {
        let point = CursorMapping.gamePoint(
            mouse: CGPoint(x: 5, y: 300), window: CGRect(x: 0, y: 0, width: 1000, height: 600),
            screen: CGSize(width: 1000, height: 600), fullscreen: false, resizable: true)
        #expect(point == nil)
    }
}

// MARK: - Dispatcher and actions

@Suite("Dispatcher and actions") @MainActor
struct ActionTests {
    private func transform(_ x: CGFloat, _ y: CGFloat, size: CGFloat = 10) -> KeyModelTransform {
        KeyModelTransform(size: size, xCoord: x, yCoord: y)
    }

    @Test("A key taps its point while held")
    func button() {
        let injector = RecordingInjector()
        let dispatcher = ActionDispatcher()
        let metrics = ScreenMetrics(bounds: injector.screenBounds)
        dispatcher.add(ButtonAction(element: ButtonElement(keyCode: 8, keyName: "", transform: transform(0.5, 0.5)),
                                    metrics: metrics, injector: injector, dispatcher: dispatcher))
        #expect(dispatcher.dispatch(key: "E", pressed: true))
        #expect(dispatcher.dispatch(key: "E", pressed: false))
        #expect(injector.events.map(\.phase) == [.began, .ended])
        #expect(injector.events.first?.point == CGPoint(x: 500, y: 250))
    }

    @Test("A toggle button holds after one press and lifts on the next")
    func toggleButton() {
        let injector = RecordingInjector()
        let dispatcher = ActionDispatcher()
        let metrics = ScreenMetrics(bounds: injector.screenBounds)
        dispatcher.add(ButtonAction(element: ButtonElement(keyCode: 8, keyName: "", transform: transform(0.5, 0.5), toggle: true),
                                    metrics: metrics, injector: injector, dispatcher: dispatcher))
        dispatcher.dispatch(key: "E", pressed: true)
        dispatcher.dispatch(key: "E", pressed: false)
        #expect(injector.events.map(\.phase) == [.began])
        dispatcher.dispatch(key: "E", pressed: true)
        dispatcher.dispatch(key: "E", pressed: false)
        #expect(injector.events.map(\.phase) == [.began, .ended])
    }

    @Test("Unmapped keys are not consumed")
    func unmapped() {
        let dispatcher = ActionDispatcher()
        #expect(!dispatcher.dispatch(key: "Q", pressed: true))
    }

    @Test("Released joystick state does not revive an old direction")
    func joystickReset() async {
        let injector = RecordingInjector()
        let dispatcher = ActionDispatcher()
        let element = JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
                                      transform: transform(0.5, 0.5, size: 20))
        let joystick = KeyJoystickAction(element: element, metrics: ScreenMetrics(bounds: injector.screenBounds),
                                         injector: injector, dispatcher: dispatcher)
        joystick.keyChanged(index: 0, pressed: true)
        joystick.invalidate()
        joystick.keyChanged(index: 3, pressed: true)
        await injector.settle(until: 4)  // began, cancelled, began, then the delayed move
        #expect(injector.events.map(\.phase) == [.began, .ended, .began, .moved])
        #expect(injector.events.last?.point == CGPoint(x: 550, y: 250))
        joystick.keyChanged(index: 3, pressed: false)
        #expect(injector.events.last?.phase == .ended)
    }

    #if canImport(GameController)
    @Test func virtualMappingWorksWithoutTouchMappingAndNativeClicksPassThrough() {
        final class Environment: InputEnvironment {
            func cursorPoint() -> CGPoint? { CGPoint(x: 100, y: 100) }
            func setCursorHidden(_ hidden: Bool) {}
            var isFullscreen: Bool { false }
            func setMenuBarVisible(_ visible: Bool) {}
        }
        var settings = GameSettings()
        settings.mulg.controls.playMode = .virtualController
        let injector = RecordingInjector(), dispatcher = ActionDispatcher()
        let controller = VirtualController(bindings: [ControllerBinding(keyCode: 4, element: .buttonA)],
                                           stickCurve: StickCurveSettings())
        defer { controller.disconnect() }
        let router = InputRouter(settings: settings, dispatcher: dispatcher, hotkeys: HotkeyCenter(), events: EventBus(),
            environment: Environment(), fakeMouse: FakeMouseAction(injector: injector), menuKeys: [])
        router.touchMappingAvailable = false
        router.virtualController = controller
        #expect(router.key(code: 0, pressed: true, isRepeat: false, flags: 0))
        #expect(controller.controller.extendedGamepad?.buttonA.isPressed == true)
        #expect(router.key(code: 0, pressed: false, isRepeat: false, flags: 0))
        #expect(controller.controller.extendedGamepad?.buttonA.isPressed == false)
        #expect(!router.mouseButton(0, pressed: true))
        #expect(!router.scroll(dx: 0, dy: 1))
        #expect(injector.events.isEmpty)
    }

    @Test("A virtual button stays held until all its bound keys are released")
    func sharedControllerButton() {
        let controller = VirtualController(bindings: [ControllerBinding(keyCode: 4, element: .buttonA),
                                                       ControllerBinding(keyCode: 5, element: .buttonA)],
                                           stickCurve: StickCurveSettings())
        defer { controller.disconnect() }
        controller.key(code: 4, pressed: true)
        controller.key(code: 5, pressed: true)
        controller.key(code: 4, pressed: false)
        #expect(controller.controller.extendedGamepad?.buttonA.isPressed == true)
        controller.key(code: 5, pressed: false)
        #expect(controller.controller.extendedGamepad?.buttonA.isPressed == false)
    }
    #endif

    @Test("A floating joystick's delayed move uses the newest stick position")
    func floatingJoystickLatestPosition() async throws {
        let injector = RecordingInjector()
        let dispatcher = ActionDispatcher()
        let element = JoystickElement(upKeyCode: 0, rightKeyCode: 0, downKeyCode: 0, leftKeyCode: 0,
                                      keyName: "Left Thumbstick", transform: transform(0.5, 0.5, size: 20), mode: .FLOATING)
        let joystick = AnalogJoystickAction(element: element, metrics: ScreenMetrics(bounds: injector.screenBounds),
                                            injector: injector, dispatcher: dispatcher)
        joystick.thumbstickMoved(x: 1, y: 0)
        joystick.thumbstickMoved(x: 0, y: 1)
        // The neutral origin first; the one delayed move then goes where the stick is now (up).
        await injector.settle(until: 2)
        try await Task.sleep(for: .milliseconds(60))
        #expect(injector.events.map(\.phase) == [.began, .moved])
        #expect(injector.events.last?.point == CGPoint(x: 500, y: 200))
    }

    @Test("Losing focus lifts both trackpad fingers")
    func trackpadFocusLoss() {
        final class Environment: InputEnvironment {
            func cursorPoint() -> CGPoint? { nil }
            func setCursorHidden(_ hidden: Bool) {}
            var isFullscreen: Bool { false }
            func setMenuBarVisible(_ visible: Bool) {}
        }
        var settings = GameSettings()
        settings.mulg.controls.cursorKeyBehaviour = .hold
        let dispatcher = ActionDispatcher()
        dispatcher.register(key: KeymapNames.mouseMove) { _, _ in }
        let injector = RecordingInjector()
        let router = InputRouter(settings: settings, dispatcher: dispatcher, hotkeys: HotkeyCenter(), events: EventBus(),
                                 environment: Environment(), fakeMouse: FakeMouseAction(injector: injector), menuKeys: [])
        let gestures = TrackpadGestures(injector: injector) { ScreenMetrics(bounds: injector.screenBounds) }
        router.gestures = gestures
        #expect(router.magnify(0, phase: 1))
        #expect(gestures.isActive)
        router.focusLost()
        #expect(!gestures.isActive)
        #expect(injector.events.map(\.phase) == [.began, .began, .ended, .ended])
    }

    @Test("WASD moves a fixed joystick and releases at the centre")
    func keyJoystick() async {
        let injector = RecordingInjector()
        let dispatcher = ActionDispatcher()
        let metrics = ScreenMetrics(bounds: injector.screenBounds)
        let element = JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
                                      transform: transform(0.2, 0.7, size: 20))
        dispatcher.add(KeyJoystickAction(element: element, metrics: metrics, injector: injector, dispatcher: dispatcher))
        dispatcher.dispatch(key: "W", pressed: true)
        await injector.settle(until: 2)
        dispatcher.dispatch(key: "D", pressed: true)
        dispatcher.dispatch(key: "W", pressed: false)
        dispatcher.dispatch(key: "D", pressed: false)
        #expect(injector.events.map(\.phase) == [.began, .moved, .moved, .moved, .ended])
        // Size 20 % of 1000 = 200 points; the joystick moves a quarter of that.
        #expect(injector.events[0].point == CGPoint(x: 200, y: 350))
        #expect(injector.events[1].point == CGPoint(x: 200, y: 350 - 50))
    }

    @Test("Releasing non-buttons keeps held keys pressed (hold-Option)")
    func partialRelease() {
        let injector = RecordingInjector()
        let dispatcher = ActionDispatcher()
        let metrics = ScreenMetrics(bounds: injector.screenBounds)
        dispatcher.add(ButtonAction(element: ButtonElement(keyCode: 26, keyName: "", transform: transform(0.1, 0.1)),
                                    metrics: metrics, injector: injector, dispatcher: dispatcher))
        let fakeMouse = FakeMouseAction(injector: injector)
        dispatcher.add(fakeMouse)
        dispatcher.dispatch(key: "W", pressed: true)
        fakeMouse.press(at: CGPoint(x: 300, y: 300))
        dispatcher.invalidateNonButtons()
        #expect(!fakeMouse.isPressed)
        #expect(injector.events.filter { $0.phase == .ended }.count == 1)
    }

    @Test("Draggable registrations win over camera ones and can be removed")
    func priorities() {
        let dispatcher = ActionDispatcher()
        var calls: [String] = []
        dispatcher.register(key: "Mouse", priority: .camera) { _, _ in calls.append("camera") }
        dispatcher.register(key: "Mouse", priority: .draggable) { _, _ in calls.append("drag") }
        dispatcher.dispatch(key: "Mouse", x: 1, y: 1)
        dispatcher.unregister(key: "Mouse")
        dispatcher.dispatch(key: "Mouse", x: 1, y: 1)
        #expect(calls == ["drag", "camera"])
    }

    @Test("Swipes slow down so they don't leave the screen before gaining inertia")
    func swipeVelocity() {
        let screen = ScreenMetrics(width: 1000, height: 500)
        let scale = SwipeAction.velocityScale(predicted: CGPoint(x: 1200, y: 250), now: CGPoint(x: 900, y: 250), screen: screen)
        #expect(abs(scale - 100.0 / 300.0) < 1e-9)
    }

    #if canImport(GameController)
    @Test("Controller camera steps scale with time, so 120 Hz turns as fast as 60 Hz")
    func stickSteps() {
        #expect(abs(ControllerInput.stepScale(elapsed: .microseconds(16_667)) - 1) < 1e-9)
        #expect(abs(ControllerInput.stepScale(elapsed: .microseconds(8_333)) * 2 - 1) < 1e-3)
        #expect(ControllerInput.stepScale(elapsed: .seconds(1)) == 3)  // no jump after a stall
    }
    #endif

    @Test("Held keys lift their touch when released under ⌘ or when the game loses focus")
    func releaseUnderCommand() {
        final class Environment: InputEnvironment {
            func cursorPoint() -> CGPoint? { nil }
            func setCursorHidden(_ hidden: Bool) {}
            var isFullscreen: Bool { false }
            func setMenuBarVisible(_ visible: Bool) {}
        }
        let injector = RecordingInjector()
        let dispatcher = ActionDispatcher()
        dispatcher.add(ButtonAction(element: ButtonElement(keyCode: 26, keyName: "", transform: transform(0.1, 0.1)),
                                    metrics: ScreenMetrics(bounds: injector.screenBounds), injector: injector,
                                    dispatcher: dispatcher))
        let router = InputRouter(settings: GameSettings(), dispatcher: dispatcher, hotkeys: HotkeyCenter(),
                                 events: EventBus(), environment: Environment(),
                                 fakeMouse: FakeMouseAction(injector: injector), menuKeys: [])
        let command: UInt = 1 << 20
        #expect(router.key(code: 0x0D, pressed: true, isRepeat: false, flags: 0))  // W
        #expect(!router.key(code: 0x0C, pressed: true, isRepeat: false, flags: command))  // ⌘Q stays the app's
        #expect(router.key(code: 0x0D, pressed: false, isRepeat: false, flags: command))
        #expect(injector.events.map(\.phase) == [.began, .ended])

        // Focus lost while W is held: the release goes to another app, so the touch lifts now.
        #expect(router.key(code: 0x0D, pressed: true, isRepeat: false, flags: 0))
        router.focusLost()
        #expect(injector.events.map(\.phase) == [.began, .ended, .began, .ended])
        router.focusGained()
        #expect(router.key(code: 0x0D, pressed: true, isRepeat: false, flags: 0))
        router.textInputBegan()
        #expect(injector.events.last?.phase == .ended)
        #expect(!router.key(code: 0x24, pressed: true, isRepeat: true, flags: 0))
        #expect(!router.modifier(code: 0x3A, pressed: true, flags: 1 << 19))
        #expect(router.mode == .textInput)
        router.textInputEnded()
        #expect(router.mode == .cursor) // Toggle mode resumes in the cursor, as before.
    }

    @Test("Mouse movement collected while inactive does not move the camera later")
    func mouseAcrossFocusChange() {
        final class Environment: InputEnvironment {
            func cursorPoint() -> CGPoint? { nil }
            func setCursorHidden(_ hidden: Bool) {}
            var isFullscreen: Bool { false }
            func setMenuBarVisible(_ visible: Bool) {}
        }
        let injector = RecordingInjector()
        let dispatcher = ActionDispatcher()
        var deliveries = 0
        dispatcher.register(key: KeymapNames.mouseMove, priority: .camera) { _, _ in deliveries += 1 }
        let router = InputRouter(settings: GameSettings(), dispatcher: dispatcher, hotkeys: HotkeyCenter(),
                                 events: EventBus(), environment: Environment(),
                                 fakeMouse: FakeMouseAction(injector: injector), menuKeys: [])
        #expect(router.mode == .camera)
        router.setEditorOpen(true)
        router.setEditorOpen(false)
        _ = router.mouseMoved(dx: 1, dy: 1)
        router.frameStarts()
        #expect(deliveries == 1)

        let raw = RawMouse()
        router.rawMouse = raw
        router.focusLost()
        _ = raw.add(dx: 40, dy: 0)
        router.rawMouseMoved()
        #expect(!router.mouseMoved(dx: 2, dy: 2))
        router.frameStarts()
        router.focusGained()
        router.frameStarts()
        #expect(deliveries == 1)

        _ = router.mouseMoved(dx: 3, dy: 3)
        router.frameStarts()
        #expect(deliveries == 2)
    }
}

// MARK: - Keymap compatibility

@Suite("Keymap files")
struct KeymapFileTests {
    @Test("An upstream keymap decodes, including joysticks without a mode")
    func upstreamKeymap() throws {
        let upstream: [String: Any] = [
            "bundleIdentifier": "com.miHoYo.GenshinImpact",
            "version": "2.0.0",
            "buttonModels": [["keyCode": 8, "keyName": "E", "transform": ["size": 5, "xCoord": 0.8, "yCoord": 0.7]]],
            "draggableButtonModels": [],
            "joystickModel": [["upKeyCode": 26, "rightKeyCode": 7, "downKeyCode": 22, "leftKeyCode": 4,
                               "keyName": "Keyboard", "transform": ["size": 20, "xCoord": 0.15, "yCoord": 0.7]]],
            "mouseAreaModel": [["keyName": "Mouse", "transform": ["size": 50, "xCoord": 0.6, "yCoord": 0.4]]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: upstream, format: .xml, options: 0)
        let keymap = try PropertyListDecoder().decode(KeymappingData.self, from: data)
        #expect(keymap.buttonModels.count == 1)
        #expect(keymap.joystickModel.first?.effectiveMode == .FIXED)
        #expect(keymap.joystickModel.first?.isAnalog == false)
        #expect(keymap.mouseAreaModel.first?.keyName == "Mouse")
        #expect(keymap.mulgControllerBindings == nil)
        #expect(keymap.isSupportedVersion)
    }

    @Test("Key names match upstream for letters, modifiers and mouse buttons")
    func names() {
        #expect(KeymapKeyNames.name(forVirtualKeyCode: 0x0D) == "W")
        #expect(KeymapKeyNames.name(forVirtualKeyCode: 0x38) == "Lshft")
        #expect(KeymapKeyNames.name(forVirtualKeyCode: 0x31) == "Spc")
        #expect(KeymapKeyNames.name(forMouseButton: 0) == "LMB")
        #expect(KeymapKeyNames.name(forMouseButton: 4) == "MBtn4")
    }

    @Test("Analog joysticks are the ones whose name contains a 'u', as upstream decided")
    func analog() {
        for (name, analog) in [("Mouse", true), ("Left Thumbstick", true), ("Keyboard", false), ("Dynamic", false)] {
            let element = JoystickElement(upKeyCode: 0, rightKeyCode: 0, downKeyCode: 0, leftKeyCode: 0,
                                          keyName: name, transform: KeyModelTransform(size: 1, xCoord: 0, yCoord: 0))
            #expect(element.isAnalog == analog, "\(name)")
        }
    }

    @Test("A missing keymap folder creates an empty default keymap")
    func newGame() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mulg-keymap-\(UUID().uuidString)")
        let loaded = KeymapStore(folder: folder, bundleIdentifier: "com.example").loadDefault()
        #expect(loaded.problems.isEmpty)
        #expect(loaded.keymap.buttonModels.isEmpty)
        #expect(FileManager.default.fileExists(atPath: loaded.file.path))
    }

    @Test("Genshin defaults bind WASD to the left stick and attack to a face button")
    func genshinDefaults() {
        let bindings = Dictionary(uniqueKeysWithValues: GenshinDefaults.controllerBindings.map { ($0.keyCode, $0.element) })
        #expect(bindings[26] == .leftStickUp)
        #expect(bindings[-1] == .buttonB)
        #expect(GenshinDefaults.menuKeys.contains("M"))
    }
}

@Suite("Raw mouse calibration")
@MainActor
struct RawMouseCalibrationTests {
    @Test("Learns flipped axes and the scale, and passes nothing through while learning")
    func learns() {
        var calibration = RawMouseCalibration()
        // This mouse reports y upside down and in half the cursor's units.
        for step in 0..<200 {
            let sign: CGFloat = step.isMultiple(of: 3) ? -1 : 1
            calibration.cursorMoved(dx: 4 * sign, dy: 2 * sign)
            #expect(calibration.adjust(CGVector(dx: 2 * sign, dy: -1 * sign)) == nil)
        }
        #expect(calibration.isReady)
        #expect(calibration.adjust(CGVector(dx: 3, dy: 5)) == CGVector(dx: 6, dy: -10))
    }

    @Test("Waits until both axes have moved")
    func waitsForBothAxes() {
        var calibration = RawMouseCalibration()
        for _ in 0..<500 {
            calibration.cursorMoved(dx: 4, dy: 0)
            _ = calibration.adjust(CGVector(dx: 2, dy: 0))
        }
        #expect(!calibration.isReady)
    }
}

@Suite("Native web pointer routing") @MainActor
struct NativeInterfaceTests {
    final class Environment: InputEnvironment {
        var hidden = false
        func cursorPoint() -> CGPoint? { CGPoint(x: 100, y: 100) }
        func setCursorHidden(_ hidden: Bool) { self.hidden = hidden }
        var isFullscreen: Bool { false }
        func setMenuBarVisible(_ visible: Bool) {}
    }

    @Test("A native drag keeps down, movement and up; gameplay mappings resume afterwards")
    func dragAndResume() {
        let environment = Environment(), injector = RecordingInjector(), dispatcher = ActionDispatcher()
        var cameraEvents = 0, clicks: [Bool] = []
        dispatcher.register(key: KeymapNames.mouseMove, priority: .camera) { _, _ in cameraEvents += 1 }
        dispatcher.register(key: KeymapKeyNames.name(forMouseButton: 0)) { clicks.append($0) }
        dispatcher.add(ButtonAction(element: ButtonElement(keyCode: 26, keyName: "",
            transform: KeyModelTransform(size: 10, xCoord: 0.1, yCoord: 0.1)),
            metrics: ScreenMetrics(bounds: injector.screenBounds), injector: injector, dispatcher: dispatcher))
        var settings = GameSettings()
        settings.noKMOnInput = false // Native web gestures must work independently of this preference.
        settings.mulg.controls.cursorKeyBehaviour = .hold
        let router = InputRouter(settings: settings, dispatcher: dispatcher, hotkeys: HotkeyCenter(), events: EventBus(),
            environment: environment, fakeMouse: FakeMouseAction(injector: injector), menuKeys: [])
        router.start()
        #expect(router.mode == .camera && environment.hidden)
        #expect(router.key(code: 0x0D, pressed: true, isRepeat: false, flags: 0))
        router.setNativeInterfaceActive(true)
        #expect(injector.events.map(\.phase) == [.began, .ended])
        #expect(router.mode == .textInput && !environment.hidden)
        #expect(!router.mouseButton(0, pressed: true))
        #expect(!router.mouseMoved(dx: 200, dy: 0))
        #expect(!router.key(code: 0x0D, pressed: true, isRepeat: false, flags: 0))
        #expect(!router.modifier(code: 0x3A, pressed: true, flags: 1 << 19))
        #expect(!router.scroll(dx: 0, dy: 10))
        router.setNativeInterfaceActive(false) // Page dismissed before the physical button is released.
        #expect(router.nativeInterfaceActive && !environment.hidden)
        #expect(!router.mouseMoved(dx: 80, dy: 0))
        #expect(!router.mouseButton(0, pressed: false))
        #expect(!router.nativeInterfaceActive && router.mode == .camera && environment.hidden)
        #expect(injector.events.count == 2 && clicks.isEmpty && cameraEvents == 0)
        #expect(router.mouseButton(0, pressed: true))
        #expect(router.mouseButton(0, pressed: false))
        #expect(clicks == [true, false])
        #expect(router.key(code: 0x0D, pressed: true, isRepeat: false, flags: 0))
        #expect(router.key(code: 0x0D, pressed: false, isRepeat: false, flags: 0))
        #expect(injector.events.map(\.phase) == [.began, .ended, .began, .ended])
    }

    @Test("Focus loss cancels ownership; web dismissal preserves the Option-tapped cursor mode")
    func focusAndCursor() {
        let environment = Environment(), injector = RecordingInjector(), dispatcher = ActionDispatcher()
        dispatcher.register(key: KeymapNames.mouseMove, priority: .camera) { _, _ in }
        var settings = GameSettings()
        settings.mulg.controls.cursorKeyBehaviour = .hold
        let router = InputRouter(settings: settings, dispatcher: dispatcher, hotkeys: HotkeyCenter(), events: EventBus(),
            environment: environment, fakeMouse: FakeMouseAction(injector: injector), menuKeys: [])
        // A tap of Option shows the cursor and keeps it (2026-10-10: like a middle click).
        _ = router.modifier(code: 0x3A, pressed: true, flags: 1 << 19)
        _ = router.modifier(code: 0x3A, pressed: false, flags: 0)
        #expect(router.mode == .cursor)
        router.setNativeInterfaceActive(true)
        router.setNativeInterfaceActive(false)
        #expect(router.mode == .cursor && !environment.hidden)
        _ = router.modifier(code: 0x3A, pressed: true, flags: 1 << 19)
        _ = router.modifier(code: 0x3A, pressed: false, flags: 0)
        #expect(router.mode == .camera)
        router.setNativeInterfaceActive(true)
        _ = router.mouseButton(0, pressed: true)
        router.setNativeInterfaceActive(false)
        router.focusLost()
        #expect(!router.nativeInterfaceActive && !environment.hidden)
        router.focusGained()
        #expect(router.mode == .camera && environment.hidden)
    }
}

@Suite("Desktop mouse gameplay startup") @MainActor
struct DesktopMouseStartupTests {
    @Test("Combat releases preserve a camera sweep and recover after a pause")
    func cameraRecoveryWaitsForPause() throws {
        let injector = RecordingInjector(), dispatcher = ActionDispatcher()
        let metrics = ScreenMetrics(bounds: injector.screenBounds)
        let camera = CameraAction(element: MouseAreaElement(keyName: KeymapNames.mouseMove,
            transform: KeyModelTransform(size: 25, xCoord: 0.5, yCoord: 0.5)), metrics: metrics,
            injector: injector, dispatcher: dispatcher, liveMetrics: { metrics })
        dispatcher.add(camera)
        let attack = KeymapKeyNames.name(forMouseButton: 0)
        dispatcher.add(ButtonAction(element: ButtonElement(keyCode: -1, keyName: "",
            transform: KeyModelTransform(size: 10, xCoord: 0.83, yCoord: 0.79)),
            metrics: metrics, injector: injector, dispatcher: dispatcher))

        var now = ContinuousClock.now
        camera.moved(dx: 2, dy: 0, at: now)
        let original = try #require(injector.events.last?.id)
        for _ in 0..<20 {
            #expect(dispatcher.dispatch(key: attack, pressed: true, source: .mouse))
            now += .milliseconds(8)
            camera.moved(dx: 2, dy: 0, at: now)
            #expect(dispatcher.dispatch(key: attack, pressed: false, source: .mouse))
            now += .milliseconds(8)
            camera.moved(dx: 2, dy: 0, at: now)
            #expect(injector.events.last?.id == original)
        }

        // A pause is insufficient while another skill is held.
        #expect(dispatcher.dispatch(key: attack, pressed: true, source: .mouse))
        now += .milliseconds(120)
        camera.moved(dx: 2, dy: 0, at: now)
        #expect(injector.events.last?.id == original)
        #expect(dispatcher.dispatch(key: attack, pressed: false, source: .mouse))
        now += .milliseconds(120)
        camera.moved(dx: 2, dy: 0, at: now)
        let replacement = try #require(injector.events.last?.id)
        #expect(replacement != original)
        #expect(camera.inputDiagnostics?["gestureRenewals"] == 1)
        now += .milliseconds(120)
        camera.moved(dx: 2, dy: 0, at: now)
        #expect(injector.events.last?.id == replacement)
    }

    @Test("Actions loaded after router creation start mouse-look; attack holds independently of camera")
    func lateKeymapCameraAndAttack() async throws {
        let environment = NativeInterfaceTests.Environment()
        let injector = RecordingInjector(), dispatcher = ActionDispatcher()
        var settings = GameSettings()
        settings.mulg.controls.cursorKeyBehaviour = .hold
        let router = InputRouter(settings: settings, dispatcher: dispatcher, hotkeys: HotkeyCenter(), events: EventBus(),
            environment: environment, fakeMouse: FakeMouseAction(injector: injector), menuKeys: GenshinDefaults.menuKeys)
        // The real module builds the router first, then loads the keymap actions.
        let metrics = ScreenMetrics(bounds: injector.screenBounds)
        let attack = KeyModelTransform(size: 10, xCoord: 0.8266, yCoord: 0.7893)
        dispatcher.add(ButtonAction(element: ButtonElement(keyCode: -1, keyName: "", transform: attack),
            metrics: metrics, injector: injector, dispatcher: dispatcher))
        dispatcher.add(CameraAction(element: MouseAreaElement(keyName: "Mouse",
            transform: KeyModelTransform(size: 25, xCoord: 0.4777, yCoord: 0.4030)),
            metrics: metrics, injector: injector, dispatcher: dispatcher,
            liveMetrics: { ScreenMetrics(bounds: injector.screenBounds) }))
        router.keymapRebuilt(); router.start()
        #expect(router.mode == .camera && environment.hidden)
        #expect(router.mouseButton(0, pressed: true))
        let contact = try #require(injector.events.last)
        #expect(contact.phase == .began && contact.point == metrics.point(attack))
        #expect(router.mouseMoved(dx: 30, dy: -10))
        try await Task.sleep(for: .milliseconds(40))
        #expect(router.mouseMoved(dx: 20, dy: 5))
        try await Task.sleep(for: .milliseconds(700))
        #expect(injector.events.contains { $0.id != contact.id && $0.phase == .moved })
        #expect(injector.events.filter { $0.id == contact.id }.map(\.phase) == [.began],
            "Camera movement and its idle timeout cannot release a charged attack")
        #expect(router.mouseButton(0, pressed: false))
        #expect(injector.events.filter { $0.id == contact.id }.map(\.phase) == [.began, .ended])
        // A short second press is a normal attack, with a new touch and one release.
        #expect(router.mouseButton(0, pressed: true))
        #expect(router.mouseButton(0, pressed: false))
        #expect(injector.events.suffix(2).map(\.phase) == [.began, .ended])
        router.focusLost()
    }

    @Test("Charged attack releases at its binding after Option shows the cursor")
    func mappedReleaseSurvivesCursorChange() throws {
        let environment = NativeInterfaceTests.Environment()
        let injector = RecordingInjector(), dispatcher = ActionDispatcher()
        var settings = GameSettings()
        settings.mulg.controls.cursorKeyBehaviour = .hold
        let router = InputRouter(settings: settings, dispatcher: dispatcher, hotkeys: HotkeyCenter(), events: EventBus(),
            environment: environment, fakeMouse: FakeMouseAction(injector: injector), menuKeys: [])
        // A mouse-look keymap: camera mode is where releasing Option returns.
        dispatcher.register(key: KeymapNames.mouseMove) { _, _ in }
        dispatcher.add(ButtonAction(element: ButtonElement(keyCode: -1, keyName: "",
            transform: KeyModelTransform(size: 10, xCoord: 0.83, yCoord: 0.79)),
            metrics: ScreenMetrics(bounds: injector.screenBounds), injector: injector, dispatcher: dispatcher))
        router.keymapRebuilt(); router.start()
        #expect(router.mouseButton(0, pressed: true))
        let attack = try #require(injector.events.last)
        _ = router.modifier(code: 0x3A, pressed: true, flags: 1 << 19)
        _ = router.modifier(code: 0x3A, pressed: false, flags: 0)
        #expect(router.mode == .cursor && !environment.hidden)
        // Resize/reload must not close the menu or return to camera mode: a tapped cursor is pinned (the
        // refresh used to send it back to the camera, so clicking anything right after showing it hid it).
        router.keymapRebuilt(); router.start()
        #expect(router.mode == .cursor)
        #expect(router.mouseButton(0, pressed: false))
        #expect(injector.events.filter { $0.id == attack.id }.map(\.phase) == [.began, .ended])
        #expect(injector.events.last?.point == attack.point)
        // New cursor clicks still tap the interface, rather than attacking.
        #expect(router.mouseButton(0, pressed: true))
        #expect(injector.events.last?.point == environment.cursorPoint())
        #expect(router.mouseButton(0, pressed: false))
        _ = router.modifier(code: 0x3A, pressed: true, flags: 1 << 19)
        _ = router.modifier(code: 0x3A, pressed: false, flags: 0)
        #expect(router.mode == .camera)
        router.focusLost()
    }

    @Test("Option held for a shortcut is not a tap: the cursor stays as it was")
    func optionChordIsNotATap() {
        let environment = NativeInterfaceTests.Environment(), injector = RecordingInjector(), dispatcher = ActionDispatcher()
        dispatcher.register(key: KeymapNames.mouseMove) { _, _ in }
        let router = InputRouter(settings: GameSettings(), dispatcher: dispatcher, hotkeys: HotkeyCenter(), events: EventBus(),
            environment: environment, fakeMouse: FakeMouseAction(injector: injector), menuKeys: [])
        router.keymapRebuilt(); router.start()
        let before = router.mode
        _ = router.modifier(code: 0x3A, pressed: true, flags: 1 << 19)
        _ = router.key(code: 0x05, pressed: true, isRepeat: false, flags: 1 << 19)   // ⌥G
        _ = router.key(code: 0x05, pressed: false, isRepeat: false, flags: 1 << 19)
        _ = router.modifier(code: 0x3A, pressed: false, flags: 0)
        #expect(router.mode == before)
        router.focusLost()
    }

    @Test("A controller-only hold-mode keymap also starts mouse-look")
    func virtualControllerStartsWithoutTouchArea() {
        let environment = NativeInterfaceTests.Environment(), injector = RecordingInjector()
        var settings = GameSettings()
        settings.mulg.controls.cursorKeyBehaviour = .hold
        settings.mulg.controls.playMode = .virtualController
        let router = InputRouter(settings: settings, dispatcher: ActionDispatcher(), hotkeys: HotkeyCenter(), events: EventBus(),
            environment: environment, fakeMouse: FakeMouseAction(injector: injector), menuKeys: [])
        // ControlsModule always resolves the control plan from the keymap before starting.
        router.keymapRebuilt(KeymappingData(bundleIdentifier: "com.example.controller"))
        router.start()
        #expect(router.mode == .camera && environment.hidden)
        router.focusLost()
    }
}

@Suite("Fluid movement and contextual gameplay") @MainActor
struct FluidGameplayTests {
    @Test("WASD starts at center immediately, opposites cancel, diagonals stay circular, and walking is live")
    func centeredMovement() async throws {
        let injector = RecordingInjector(), dispatcher = ActionDispatcher()
        let center = CGPoint(x: 160, y: 390)
        let action = KeyJoystickAction(element: JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
            transform: KeyModelTransform(size: 20, xCoord: 0.16, yCoord: 0.78), mode: .FLOATING),
            metrics: ScreenMetrics(bounds: injector.screenBounds), injector: injector, dispatcher: dispatcher)
        dispatcher.add(action)
        #expect(dispatcher.dispatch(key: "W", pressed: true))
        await injector.settle(until: 2)
        #expect(injector.events.map(\.phase) == [.began, .moved])
        try #require(injector.events.count >= 2)
        #expect(injector.events[0].point == center && injector.events[1].point == CGPoint(x: 160, y: 340))
        dispatcher.dispatch(key: "D", pressed: true)
        var point = try #require(injector.events.last?.point)
        #expect(abs(hypot(point.x - center.x, point.y - center.y) - 50) < 0.001)
        #expect(abs((point.x - center.x) + (point.y - center.y)) < 0.001)
        dispatcher.setWalking(true)
        point = try #require(injector.events.last?.point)
        #expect(abs(hypot(point.x - center.x, point.y - center.y) - 17.5) < 0.001)
        dispatcher.dispatch(key: "A", pressed: true)
        #expect(injector.events.last?.point.x == center.x)
        dispatcher.dispatch(key: "S", pressed: true)
        #expect(injector.events.last?.phase == .ended)
        // A release lifts where the finger last was (walking up: 0.35 × 50 above the centre), never via a
        // backwards trip to the centre the game would read as a flick.
        let lifted = try #require(injector.events.last?.point)
        #expect(lifted.x == center.x && abs(lifted.y - 372.5) < 0.001)
        dispatcher.dispatch(key: "S", pressed: false)
        await injector.settle(until: injector.events.count + 2)
        #expect(injector.events.suffix(2).map(\.phase) == [.began, .moved])
        #expect(injector.events.last?.point == CGPoint(x: 160, y: 372.5))
        dispatcher.invalidateAll()
        #expect(injector.events.last?.phase == .ended)
    }

    @Test("Smooth movement: a release lifts at once (never a backwards centre), and a floating stick moves after two frames")
    func smoothMovementFrames() async throws {
        let injector = RecordingInjector(), dispatcher = ActionDispatcher()
        let center = CGPoint(x: 160, y: 390)
        let action = KeyJoystickAction(element: JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
            transform: KeyModelTransform(size: 20, xCoord: 0.16, yCoord: 0.78), mode: .FLOATING),
            metrics: ScreenMetrics(bounds: injector.screenBounds), injector: injector, dispatcher: dispatcher,
            framePacedActivation: true)
        dispatcher.add(action)
        dispatcher.dispatch(key: "W", pressed: true)
        await injector.settle(until: 1)
        #expect(injector.events.map(\.phase) == [.began] && injector.events[0].point == center)
        // Frames, not the 40 ms limit, release the move: wait until the stick waits, tick twice,
        // and the move must follow at once (well inside 40 ms).
        let clock = ContinuousClock(), deadline = clock.now + .seconds(1)
        while FrameTicker.shared.pendingWaiters == 0, clock.now < deadline { await Task.yield() }
        try #require(FrameTicker.shared.pendingWaiters > 0)
        let ticked = clock.now
        FrameTicker.shared.tick()
        FrameTicker.shared.tick()
        while injector.events.count < 2, clock.now - ticked < .milliseconds(30) { await Task.yield() }
        #expect(clock.now - ticked < .milliseconds(30))
        #expect(injector.events.map(\.phase) == [.began, .moved])
        #expect(injector.events.last?.point == CGPoint(x: 160, y: 340))
        // Letting go lifts the finger where it is; it never slides back through the centre.
        dispatcher.dispatch(key: "W", pressed: false)
        #expect(injector.events.map(\.phase) == [.began, .moved, .ended])
        #expect(injector.events.last?.point == CGPoint(x: 160, y: 340))
        dispatcher.invalidateAll()
    }

    @Test("Frame-paced activation still moves after the fixed limit when no frames run")
    func smoothMovementWithoutFrames() async throws {
        let injector = RecordingInjector(), dispatcher = ActionDispatcher()
        let action = KeyJoystickAction(element: JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
            transform: KeyModelTransform(size: 20, xCoord: 0.16, yCoord: 0.78), mode: .FLOATING),
            metrics: ScreenMetrics(bounds: injector.screenBounds), injector: injector, dispatcher: dispatcher,
            framePacedActivation: true)
        dispatcher.add(action)
        dispatcher.dispatch(key: "W", pressed: true)
        await injector.settle(until: 2)
        #expect(injector.events.map(\.phase) == [.began, .moved])
        dispatcher.invalidateAll()
    }

    @Test("A floating stick glides out in steps within 70 % of its radius; releasing stops the glide")
    func floatingGlide() async throws {
        let injector = RecordingInjector(), dispatcher = ActionDispatcher()
        let center = CGPoint(x: 160, y: 390)
        let action = KeyJoystickAction(element: JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
            transform: KeyModelTransform(size: 20, xCoord: 0.16, yCoord: 0.78), mode: .FLOATING),
            metrics: ScreenMetrics(bounds: injector.screenBounds), injector: injector, dispatcher: dispatcher, glide: true)
        dispatcher.add(action)
        dispatcher.dispatch(key: "W", pressed: true)
        await injector.settle(until: 4)
        let moves = injector.events.filter { $0.phase == .moved }
        #expect(injector.events.first?.phase == .began && injector.events.first?.point == center)
        #expect(moves.count == 3) // 35 points in steps of at most 50 / 3
        var previous = center
        for move in moves {
            #expect(move.point.x == center.x && previous.y - move.point.y <= 50.0 / 3 + 0.001)
            previous = move.point
        }
        #expect(abs(previous.y - (center.y - 35)) < 0.001) // 70 % of the 50-point radius
        // Opposite direction mid-glide restarts from where the finger is, then release ends there.
        dispatcher.dispatch(key: "W", pressed: false)
        let count = injector.events.count
        #expect(injector.events.last?.phase == .ended && injector.events.last?.point == previous)
        try await Task.sleep(for: .milliseconds(40))
        #expect(injector.events.count == count)
        dispatcher.invalidateAll()
    }

    @Test("Control-W walks without needing an extra Control-W binding or releasing W early")
    func walkModifier() async throws {
        let injector = RecordingInjector(), dispatcher = ActionDispatcher()
        let environment = NativeInterfaceTests.Environment()
        let element = JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
            transform: KeyModelTransform(size: 20, xCoord: 0.2, yCoord: 0.7))
        dispatcher.add(KeyJoystickAction(element: element, metrics: ScreenMetrics(bounds: injector.screenBounds),
            injector: injector, dispatcher: dispatcher))
        dispatcher.register(key: "Mouse", priority: .camera) { _, _ in }
        let router = InputRouter(settings: GameSettings(), dispatcher: dispatcher, hotkeys: HotkeyCenter(), events: EventBus(),
            environment: environment, fakeMouse: FakeMouseAction(injector: injector), menuKeys: [])
        router.start()
        _ = router.modifier(code: 0x3B, pressed: true, flags: 1 << 18)
        #expect(router.key(code: 0x0D, pressed: true, isRepeat: false, flags: 1 << 18))
        await injector.settle(until: 2)
        #expect(injector.events.last?.point == CGPoint(x: 200, y: 332.5))
        _ = router.modifier(code: 0x3B, pressed: false, flags: 0)
        #expect(injector.events.last?.point == CGPoint(x: 200, y: 300))
        #expect(router.key(code: 0x0D, pressed: false, isRepeat: false, flags: 0))
        #expect(injector.events.last?.phase == .ended)
        router.focusLost()
    }

    @Test("Camera sends the newest position on the first move and never drops edge-reset movement")
    func immediateCamera() throws {
        let injector = RecordingInjector()
        let swipe = SwipeAction(injector: injector, metrics: { ScreenMetrics(bounds: injector.screenBounds) })
        swipe.move(from: { CGPoint(x: 500, y: 250) }, dx: 10, dy: 5)
        #expect(injector.events.map(\.phase) == [.began, .moved])
        #expect(injector.events.last?.point == CGPoint(x: 510, y: 245))
        swipe.move(from: { CGPoint(x: 500, y: 250) }, dx: 15, dy: 0)
        #expect(injector.events.last?.point == CGPoint(x: 525, y: 245))
        for _ in 0..<40 { swipe.move(from: { CGPoint(x: 500, y: 250) }, dx: 100, dy: 0) }
        #expect(injector.events.filter { $0.phase == .moved }.count == 42)
        #expect(injector.events.allSatisfy { ScreenMetrics(bounds: injector.screenBounds).contains($0.point) })
        swipe.liftOff()
    }

    @Test("Camera keeps its touch when movement reverses near an edge and resets only when needed")
    func cameraEdgeReversal() throws {
        let injector = RecordingInjector()
        let swipe = SwipeAction(injector: injector, liftsWhenIdle: false,
            metrics: { ScreenMetrics(bounds: injector.screenBounds) })
        let origin = CGPoint(x: 500, y: 250)
        for _ in 0..<16 { swipe.move(from: { origin }, dx: 25, dy: 0) }
        swipe.move(from: { origin }, dx: 60, dy: 0) // Next similar movement would cross the edge.
        let initialID = try #require(injector.events.first?.id)
        swipe.move(from: { origin }, dx: -20, dy: 0)
        #expect(injector.events.allSatisfy { $0.id == initialID && $0.phase != .ended })
        #expect(injector.events.last?.point.x == 940)
        swipe.move(from: { origin }, dx: 100, dy: 0)
        swipe.move(from: { origin }, dx: 1, dy: 0)
        let begins = injector.events.filter { $0.phase == .began }
        #expect(begins.count == 2 && begins.last?.id != initialID)
        #expect(injector.events.contains { $0.id == initialID && $0.phase == .ended })
        #expect(injector.events.last?.phase == .moved)
        swipe.liftOff()
    }

    @Test("Menu keys keep the camera; Option and resume return to it; explicit resume releases held inputs")
    func recoverCursor() {
        var modes = ControlModeMachine(behaviour: .hold, pauseForTextInput: true, keymapUsesMouse: true, menuKeys: ["M"])
        _ = modes.cursorKeyPressed(); _ = modes.cursorKeyReleased()
        #expect(modes.mode == .camera)
        _ = modes.cursorClickToggled(); _ = modes.resumeGameplay()
        #expect(modes.mode == .camera)
        let injector = RecordingInjector(), dispatcher = ActionDispatcher()
        let environment = NativeInterfaceTests.Environment()
        dispatcher.register(key: KeymapNames.mouseMove) { _, _ in }  // mouse-look: gameplay is camera mode
        dispatcher.add(ButtonAction(element: ButtonElement(keyCode: -1, keyName: "", transform: KeyModelTransform(size: 5, xCoord: 0.8, yCoord: 0.8)),
            metrics: ScreenMetrics(bounds: injector.screenBounds), injector: injector, dispatcher: dispatcher))
        let router = InputRouter(settings: GameSettings(), dispatcher: dispatcher, hotkeys: HotkeyCenter(), events: EventBus(),
            environment: environment, fakeMouse: FakeMouseAction(injector: injector), menuKeys: ["M"])
        router.start(); _ = router.mouseButton(0, pressed: true)
        _ = router.key(code: 0x2E, pressed: true, isRepeat: false, flags: 0)
        #expect(router.mode == .camera, "M opens the game menu but the camera keeps the mouse")
        #expect(router.mouseButton(2, pressed: true) && router.mode == .cursor)
        #expect(router.resumeGameplay() && router.mode == .camera)
        #expect(injector.events.map(\.phase) == [.began, .ended])
        router.setNativeInterfaceActive(true)
        #expect(!router.resumeGameplay())
        router.focusLost()
    }

    @Test("Desktop movement, climbing, grappling and interaction keep their anchors on iPad and wide windows")
    func calibratedLayout() throws {
        var map = KeymappingData(bundleIdentifier: "com.miHoYo.GenshinImpact")
        map.joystickModel = [JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
            transform: KeyModelTransform(size: 24, xCoord: 0.156, yCoord: 0.788))]
        map.buttonModels = [
            ButtonElement(keyCode: 9, keyName: "", transform: KeyModelTransform(size: 4, xCoord: 0.634, yCoord: 0.528)),
            ButtonElement(keyCode: 23, keyName: "", transform: KeyModelTransform(size: 4.5, xCoord: 0.757, yCoord: 0.674)),
            ButtonElement(keyCode: 27, keyName: "", transform: KeyModelTransform(size: 10, xCoord: 0.826, yCoord: 0.789)),
            ButtonElement(keyCode: 44, keyName: "", transform: KeyModelTransform(size: 7, xCoord: 0.922, yCoord: 0.69))]
        map = GenshinDefaults.desktopTouchLayout(map)
        #expect(map.mulgAspectRatio == 16.0 / 9 && map.joystickModel[0].mode == .FLOATING)
        let bytes = try PropertyListEncoder().encode(map)
        #expect(try PropertyListDecoder().decode(KeymappingData.self, from: bytes) == map)
        for size in [CGSize(width: 1440, height: 1080), CGSize(width: 2560, height: 1080)] {
            let fitted = map.fitted(toWidth: size.width, height: size.height)
            // Each control keeps its 1920-wide pixel distance from its anchor edge, scaled by KeymapCanvas
            // scaleInHeights: 1 on the wide window, 0.75 on 4:3, where controls keep their fraction of the width.
            let scale = min(1, (size.width / size.height) / (16.0 / 9))
            #expect(abs(fitted.joystickModel[0].transform.xCoord * size.width - 0.156 * 1920 * scale) < 0.001)
            #expect(abs(fitted.joystickModel[0].transform.size * size.width / 100 - 20 * 1920 / 100 * scale) < 0.001)
            #expect(abs((fitted.buttonModels[0].transform.xCoord - 0.5) * size.width - 0.134 * 1920 * scale) < 0.001)
            for i in 1..<4 {
                #expect(abs((1 - fitted.buttonModels[i].transform.xCoord) * size.width
                    - (1 - map.buttonModels[i].transform.xCoord) * 1920 * scale) < 0.001)
            }
        }
    }
}

@Suite("Complete Genshin desktop preset") @MainActor
struct CompleteGenshinPresetTests {
    @Test("Context actions and menu aliases remain mapped; aim shooting does not expose the cursor")
    func missingBindingsAndMenus() {
        var map = KeymappingData(bundleIdentifier: "com.miHoYo.GenshinImpact")
        for code in [23, 27, 11, 9, 10, 29, 19, 28, 18, 12, 24, 43, 224] {
            map.buttonModels.append(ButtonElement(keyCode: code, keyName: "", transform: KeyModelTransform(size: 5, xCoord: 0.7, yCoord: 0.5)))
        }
        map.buttonModels.append(ButtonElement(keyCode: 15, keyName: "", transform: KeyModelTransform(size: 5, xCoord: 0.065, yCoord: 0.5)))
        map = GenshinDefaults.desktopTouchLayout(map)
        for code in [23, 27, 11, 9, 10, 29, 58, 59, 60, 61, 62, -3] {
            #expect(map.buttonModels.contains { $0.keyCode == code })
        }
        #expect(!map.buttonModels.contains { $0.keyCode == 224 })
        let menus = GenshinDefaults.menuKeys(for: map)
        #expect(!menus.contains("L") && !menus.contains("T") && !menus.contains("H"))
        #expect(menus.isSuperset(of: ["F1", "F2", "F3", "F4", "F5", "Y", "U", "I", "O", "P"]))
    }

    @Test("The expanded gliding stick never sends movement off the game surface")
    func boundedGlidingStick() {
        let injector = RecordingInjector(), dispatcher = ActionDispatcher()
        let joystick = KeyJoystickAction(element: JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
            transform: KeyModelTransform(size: 96, xCoord: 0.156, yCoord: 0.763)),
            metrics: ScreenMetrics(bounds: injector.screenBounds), injector: injector, dispatcher: dispatcher)
        for index in 0..<4 {
            joystick.keyChanged(index: index, pressed: true)
            joystick.keyChanged(index: index, pressed: false)
        }
        #expect(injector.events.allSatisfy { ScreenMetrics(bounds: injector.screenBounds).contains($0.point) })
        #expect(injector.events.filter { $0.phase == .began }.allSatisfy { $0.point == CGPoint(x: 156, y: 381.5) })
    }
}

@Suite("Native PC controls") @MainActor
struct NativePCControlsTests {
    @Test("WASD, spells, four party slots and map use controller values without any HUD coordinates")
    func gameActions() throws {
        let controller = VirtualController(bindings: GenshinDefaults.controllerBindings, stickCurve: StickCurveSettings())
        defer { controller.disconnect() }
        let pad = try #require(controller.controller.extendedGamepad)
        controller.key(code: 26, pressed: true)
        #expect(pad.leftThumbstick.yAxis.value == 1 && pad.leftThumbstick.xAxis.value == 0)
        controller.key(code: 22, pressed: true)
        #expect(pad.leftThumbstick.yAxis.value == 0)
        controller.key(code: 22, pressed: false)
        controller.key(code: 7, pressed: true)
        #expect(abs(pad.leftThumbstick.xAxis.value - 0.70710677) < 0.001)
        controller.setWalking(true)
        #expect(abs(pad.leftThumbstick.yAxis.value - 0.35355338) < 0.001)
        controller.releaseAll()
        for (code, button) in [(8, pad.rightTrigger), (20, pad.buttonY), (-1, pad.buttonB),
                              (225, pad.rightShoulder), (30, pad.dpad.up), (31, pad.dpad.right),
                              (32, pad.dpad.left), (33, pad.dpad.down), (16, try #require(pad.buttonOptions))] {
            #expect(controller.key(code: code, pressed: true) && button.isPressed)
            #expect(controller.key(code: code, pressed: false) && !button.isPressed)
        }
    }

    @Test("R toggles bow aim, left-click fires RT, and its release owns the original action")
    func aimedFireOwnership() throws {
        let controller = VirtualController(bindings: GenshinDefaults.controllerBindings, stickCurve: StickCurveSettings())
        defer { controller.disconnect() }
        let pad = try #require(controller.controller.extendedGamepad)
        controller.key(code: 21, pressed: true); controller.key(code: 21, pressed: false)
        #expect(pad.leftTrigger.isPressed)
        controller.key(code: -1, pressed: true)
        #expect(pad.rightTrigger.isPressed && !pad.buttonB.isPressed)
        controller.key(code: 21, pressed: true); controller.key(code: 21, pressed: false)
        #expect(!pad.leftTrigger.isPressed && pad.rightTrigger.isPressed)
        controller.key(code: -1, pressed: false)
        #expect(!pad.rightTrigger.isPressed && !pad.buttonB.isPressed)
        controller.key(code: -1, pressed: true)
        #expect(pad.buttonB.isPressed)
        controller.releaseAll()
        #expect(!pad.buttonB.isPressed && !pad.leftTrigger.isPressed)
    }

    @Test("Native shortcut modifiers press first, release last, and shared buttons remain owned")
    func shortcutChords() throws {
        let controller = VirtualController(bindings: GenshinDefaults.controllerBindings, stickCurve: StickCurveSettings())
        defer { controller.disconnect() }
        let pad = try #require(controller.controller.extendedGamepad)
        var seen: [String] = []
        pad.leftShoulder.pressedChangedHandler = { _, _, down in MainActor.assumeIsolated { seen.append(down ? "LB+" : "LB-") } }
        pad.buttonX.pressedChangedHandler = { _, _, down in MainActor.assumeIsolated { seen.append(down ? "X+" : "X-") } }
        controller.controller.handlerQueue = .main
        controller.key(code: 23, pressed: true)
        #expect(pad.leftShoulder.isPressed && pad.buttonX.isPressed)
        controller.key(code: 9, pressed: true)
        controller.key(code: 23, pressed: false)
        #expect(!pad.leftShoulder.isPressed && pad.buttonX.isPressed)
        controller.key(code: 9, pressed: false)
        #expect(!pad.buttonX.isPressed)
        // GameController may deliver handlers asynchronously; values above are synchronous.
        pad.leftShoulder.pressedChangedHandler = nil; pad.buttonX.pressedChangedHandler = nil
        controller.key(code: 29, pressed: true)
        controller.key(code: -1, pressed: true)
        controller.key(code: 29, pressed: false)
        #expect(pad.buttonB.isPressed && !pad.leftShoulder.isPressed)
        controller.key(code: -1, pressed: false)
        #expect(!pad.buttonB.isPressed)
    }

    @Test("Native routing works with an empty keymap at different viewport sizes and skips stale touch shortcuts")
    func independentOfViewport() throws {
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1366, height: 1024), CGSize(width: 3440, height: 1440)] {
            let injector = RecordingInjector(), dispatcher = ActionDispatcher()
            injector.screenBounds = CGRect(origin: .zero, size: size)
            let environment = NativeInterfaceTests.Environment()
            var settings = GameSettings(bundleIdentifier: "com.miHoYo.GenshinImpact")
            settings.mulg.controls.playMode = .virtualController
            settings.mulg.controls.cursorKeyBehaviour = .hold
            let router = InputRouter(settings: settings, dispatcher: dispatcher, hotkeys: HotkeyCenter(),
                events: EventBus(), environment: environment, fakeMouse: FakeMouseAction(injector: injector),
                menuKeys: GenshinDefaults.controllerMenuKeys)
            let controller = VirtualController(bindings: GenshinDefaults.controllerBindings, stickCurve: StickCurveSettings())
            defer { controller.disconnect() }
            router.virtualController = controller
            var staleTouches = 0
            dispatcher.register(key: "C") { _ in staleTouches += 1 }
            router.keymapRebuilt(genshinControllerMap())
            router.start()
            #expect(router.mode == .camera)
            #expect(router.key(code: 0x0D, pressed: true, isRepeat: false, flags: 0))
            #expect(controller.controller.extendedGamepad?.leftThumbstick.yAxis.value == 1)
            #expect(router.mouseButton(0, pressed: true))
            #expect(controller.controller.extendedGamepad?.buttonB.isPressed == true)
            #expect(!router.key(code: 0x08, pressed: true, isRepeat: false, flags: 0))
            #expect(staleTouches == 0 && injector.events.isEmpty)
            router.focusLost()
            #expect(controller.controller.extendedGamepad?.leftThumbstick.yAxis.value == 0)
            #expect(controller.controller.extendedGamepad?.buttonB.isPressed == false)
        }
    }

    @Test("Esc in play presses Menu and keeps the camera; with the cursor shown it presses Back")
    func menus() throws {
        let injector = RecordingInjector(), dispatcher = ActionDispatcher(), environment = NativeInterfaceTests.Environment()
        var settings = GameSettings(bundleIdentifier: "com.miHoYo.GenshinImpact")
        settings.mulg.controls.playMode = .virtualController
        settings.mulg.controls.cursorKeyBehaviour = .hold
        let router = InputRouter(settings: settings, dispatcher: dispatcher, hotkeys: HotkeyCenter(),
            events: EventBus(), environment: environment, fakeMouse: FakeMouseAction(injector: injector),
            menuKeys: GenshinDefaults.controllerMenuKeys)
        let controller = VirtualController(bindings: GenshinDefaults.controllerBindings, stickCurve: StickCurveSettings())
        defer { controller.disconnect() }
        router.virtualController = controller
        router.keymapRebuilt(genshinControllerMap())
        router.start()
        let pad = try #require(controller.controller.extendedGamepad)
        router.key(code: 0x35, pressed: true, isRepeat: false, flags: 0)
        #expect(router.mode == .camera && pad.buttonMenu.isPressed && !pad.buttonB.isPressed)
        router.key(code: 0x35, pressed: false, isRepeat: false, flags: 0)
        #expect(!pad.buttonMenu.isPressed)
        _ = router.modifier(code: 0x3A, pressed: true, flags: 0); _ = router.modifier(code: 0x3A, pressed: false, flags: 0)
        #expect(router.mode == .cursor, "An Option tap shows the cursor")
        router.key(code: 0x35, pressed: true, isRepeat: false, flags: 0)
        #expect(router.mode == .cursor && pad.buttonB.isPressed && !pad.buttonMenu.isPressed)
        router.key(code: 0x35, pressed: false, isRepeat: false, flags: 0)
        #expect(!pad.buttonB.isPressed)
    }

    @Test("Floating activation preserves the latest WASD direction and cancels cleanly on release")
    func polledJoystickOrigin() async throws {
        let injector = RecordingInjector(), dispatcher = ActionDispatcher()
        let element = JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
            transform: KeyModelTransform(size: 20, xCoord: 0.25, yCoord: 0.75), mode: .FLOATING,
            activationDelayMilliseconds: 40)
        let joystick = KeyJoystickAction(element: element, metrics: ScreenMetrics(bounds: injector.screenBounds), injector: injector, dispatcher: dispatcher)
        joystick.keyChanged(index: 0, pressed: true)
        #expect(injector.events.count == 1 && injector.events[0].phase == .began)
        joystick.keyChanged(index: 3, pressed: true)
        // The move follows the 40 ms activation once the touch is delivered; a busy Mac takes longer.
        await injector.settle(until: 2)
        #expect(injector.events.count == 2 && injector.events.last?.phase == .moved)
        let moved = try #require(injector.events.last)
        #expect(moved.point.x > 250 && moved.point.y < 375)
        joystick.keyChanged(index: 3, pressed: false)
        #expect(injector.events.count == 3) // already active: no second activation delay
        joystick.invalidate()
        joystick.keyChanged(index: 0, pressed: true); joystick.keyChanged(index: 0, pressed: false)
        let count = injector.events.count
        try await Task.sleep(for: .milliseconds(65))
        #expect(injector.events.count == count)
    }
}
@Suite("Native mouse frame handoff") @MainActor
struct NativeMouseFrameTests {
    @Test("A flick survives until the game samples it, then returns to center without drift")
    func frameSampledMouse() async throws {
        var curve = StickCurveSettings(); curve.deadzone = 0; curve.exponent = 1; curve.decay = 1
        let input = VirtualController(bindings: [], stickCurve: curve)
        defer { input.disconnect() }
        let pad = try #require(input.controller.extendedGamepad)
        input.mouseMoved(dx: 2, dy: 0)
        let moved = pad.rightThumbstick.xAxis.value
        #expect(moved > 0)
        try await Task.sleep(for: .milliseconds(15))
        #expect(pad.rightThumbstick.xAxis.value == moved)
        input.frameStarts()
        #expect(pad.rightThumbstick.xAxis.value == moved)
        input.frameStarts()
        #expect(pad.rightThumbstick.xAxis.value == 0)
        input.mouseMoved(dx: 2, dy: 0); input.releaseAll()
        try await Task.sleep(for: .milliseconds(55))
        #expect(pad.rightThumbstick.xAxis.value == 0)
    }
}
@Suite("Native aim cancellation") @MainActor
struct NativeAimCancelTests {
    @Test("Party switches release latched aim; Escape cancels aim before opening a menu")
    func cancelAndSwitch() throws {
        let injector = RecordingInjector(), dispatcher = ActionDispatcher(), environment = NativeInterfaceTests.Environment()
        var settings = GameSettings(bundleIdentifier: "com.miHoYo.GenshinImpact")
        settings.mulg.controls.playMode = .virtualController
        settings.mulg.controls.cursorKeyBehaviour = .hold
        let router = InputRouter(settings: settings, dispatcher: dispatcher, hotkeys: HotkeyCenter(),
            events: EventBus(), environment: environment, fakeMouse: FakeMouseAction(injector: injector),
            menuKeys: GenshinDefaults.controllerMenuKeys)
        let input = VirtualController(bindings: GenshinDefaults.controllerBindings, stickCurve: StickCurveSettings())
        defer { input.disconnect() }
        router.virtualController = input
        router.keymapRebuilt(genshinControllerMap())
        router.start()
        let pad = try #require(input.controller.extendedGamepad)
        func aim() { input.key(code: 21, pressed: true); input.key(code: 21, pressed: false) }
        aim(); input.key(code: 30, pressed: true)
        #expect(!pad.leftTrigger.isPressed && pad.dpad.up.isPressed)
        input.key(code: 30, pressed: false)
        aim(); router.key(code: 0x35, pressed: true, isRepeat: false, flags: 0)
        #expect(router.mode == .camera && !pad.leftTrigger.isPressed && pad.buttonB.isPressed && !pad.buttonMenu.isPressed)
        router.key(code: 0x35, pressed: false, isRepeat: false, flags: 0)
        #expect(!pad.buttonB.isPressed)
        let bytes = try PropertyListEncoder().encode(GenshinDefaults.controllerBindings)
        #expect(try PropertyListDecoder().decode([ControllerBinding].self, from: bytes) == GenshinDefaults.controllerBindings)
    }
}
@Suite("Connected controller ownership") @MainActor
struct ConnectedControllerOwnershipTests {
    @Test("A later system device is excluded from real-controller touch mapping")
    func excludeLaterConnection() {
        let device = GCController.withExtendedGamepad()
        let input = ControllerInput(dispatcher: ActionDispatcher(), virtualController: nil,
            isVirtualController: { $0 === device })
        input.attach(device)
        #expect(input.token(for: device) == nil)
    }

    @Test("Elemental sight uses LB and D-pad left without an optional stick-click element")
    func elementalSight() throws {
        let input = VirtualController(bindings: GenshinDefaults.controllerBindings, stickCurve: StickCurveSettings())
        defer { input.disconnect() }
        let pad = try #require(input.controller.extendedGamepad)
        input.key(code: -3, pressed: true)
        #expect(pad.leftShoulder.isPressed && pad.dpad.left.isPressed)
        #expect(pad.leftThumbstickButton?.isPressed != true)
        input.key(code: -3, pressed: false)
        #expect(!pad.leftShoulder.isPressed && !pad.dpad.left.isPressed)
    }
}
@Suite("Fluid iPad viewport reflow") @MainActor
struct FluidViewportTests {
    @Test("WASD and a held attack end where they were on each resize and resume inside wide, tall and small viewports")
    func heldInputsSurviveResize() async {
        let injector = RecordingInjector(), dispatcher = ActionDispatcher()
        injector.screenBounds = CGRect(x: 0, y: 0, width: 1376, height: 1032)
        let metrics = ScreenMetrics(bounds: injector.screenBounds)
        dispatcher.add(KeyJoystickAction(element: JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
            transform: .init(size: 20, xCoord: 0.2, yCoord: 0.75, horizontalAnchor: .left)),
            metrics: metrics, injector: injector, dispatcher: dispatcher))
        dispatcher.add(ButtonAction(element: ButtonElement(keyCode: -1, keyName: "LMB",
            transform: .init(size: 10, xCoord: 0.9, yCoord: 0.8, horizontalAnchor: .right)),
            metrics: metrics, injector: injector, dispatcher: dispatcher))
        dispatcher.dispatch(key: "W", pressed: true)
        dispatcher.dispatch(key: "LMB", pressed: true)
        await injector.settle(until: 3)
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 3440, height: 1440), CGSize(width: 720, height: 960), CGSize(width: 240, height: 800), CGSize(width: 1376, height: 1032)] {
            injector.screenBounds.size = size
            let before = injector.events.count
            dispatcher.resize(to: ScreenMetrics(bounds: injector.screenBounds))
            // Each held contact ends at its last delivered point, then resumes after the layout settles.
            #expect(injector.events[before...].map(\.phase) == [.ended, .ended])
            await injector.settle(until: before + 5)
            let resumed = injector.events[(before + 2)...]
            #expect(resumed.filter { $0.phase == .began }.count == 2 && resumed.contains { $0.phase == .moved })
            #expect(resumed.allSatisfy { ScreenMetrics(bounds: injector.screenBounds).contains($0.point) })
        }
        dispatcher.dispatch(key: "W", pressed: false)
        dispatcher.dispatch(key: "LMB", pressed: false)
        #expect(injector.events.suffix(2).allSatisfy { $0.phase == .ended })
    }

    @Test("A held aiming drag lifts where it reached on a resize, never at its button, and does not resume")
    func aimedSkillResize() {
        let injector = RecordingInjector(), dispatcher = ActionDispatcher()
        let drag = DraggableButtonAction(element: ButtonElement(keyCode: 8, keyName: "E",
            transform: .init(size: 10, xCoord: 0.8, yCoord: 0.7, horizontalAnchor: .right)),
            metrics: ScreenMetrics(bounds: injector.screenBounds), injector: injector, dispatcher: dispatcher)
        dispatcher.add(drag)
        dispatcher.dispatch(key: "E", pressed: true)
        drag.mouseMoved(dx: -50, dy: 40)
        let identity = injector.events.last?.id
        let reached = injector.events.last?.point
        let count = injector.events.count
        injector.screenBounds.size = CGSize(width: 1600, height: 1000)
        dispatcher.resize(to: ScreenMetrics(bounds: injector.screenBounds))
        // Unlike sticks and buttons, an aim is not resumed after the layout settles: a resumed aim would
        // fire the skill in a direction the player never chose. It lifts once, where it had reached.
        #expect(injector.events.count == count + 1)
        #expect(injector.events.last?.id == identity && injector.events.last?.phase == .ended)
        #expect(injector.events.last?.point == reached)
        dispatcher.dispatch(key: "E", pressed: false)
        #expect(injector.events.count == count + 1)  // nothing left to release
    }

    @Test("M5 iPad map records the 13-inch reference and leaves the window unconstrained")
    func iPadReference() {
        var map = KeymappingData(bundleIdentifier: "com.miHoYo.GenshinImpact")
        map.mulgAspectRatio = 16.0 / 9
        map.joystickModel = [JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
            transform: .init(size: 96, xCoord: 0.15, yCoord: 0.75))]
        let result = GenshinDefaults.iPadTouchLayout(map)
        #expect(result.mulgAspectRatio == 4.0 / 3 && result.mulgLockAspectRatio == false)
        let portrait = result.fitted(toWidth: 720, height: 960)
        #expect(portrait.mulgAspectRatio == 0.75)
        // Narrower than the 4:3 reference, controls scale by scaleInHeights ((3/4) / (4/3) = 0.5625) and keep
        // their share of the width: size × (4/3) × 0.5625 = size × 3/4, so the stick fits the portrait window.
        #expect(abs(portrait.joystickModel[0].transform.size - result.joystickModel[0].transform.size * 3 / 4) < 0.001)
    }
}
@Suite("Precise touchscreen joystick") @MainActor
struct JoystickPrecisionTests {
    @Test("Measured center overrides an offset map; all eight directions keep their axis and circular speed")
    func measuredAxes() async throws {
        let injector = RecordingInjector(), dispatcher = ActionDispatcher()
        let center = CGPoint(x: 163, y: 392), radius: CGFloat = 45
        let calibration = try #require(JoystickCalibration(center: center,
            edge: CGPoint(x: center.x + radius, y: center.y), width: 1000, height: 500))
        var map = KeymappingData(bundleIdentifier: "game")
        map.mulgAspectRatio = 2
        map.joystickModel = [JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
            transform: .init(size: 96, xCoord: 0.29, yCoord: 0.71), calibration: calibration)]
        let element = map.fitted(toWidth: 1376, height: 1032).joystickModel[0]
        dispatcher.add(KeyJoystickAction(element: element, metrics: ScreenMetrics(bounds: injector.screenBounds),
            injector: injector, dispatcher: dispatcher))
        for (keys, vector) in [
            (["W"], CGPoint(x: 0, y: -1)), (["S"], CGPoint(x: 0, y: 1)),
            (["A"], CGPoint(x: -1, y: 0)), (["D"], CGPoint(x: 1, y: 0)),
            (["W", "A"], CGPoint(x: -1, y: -1)), (["W", "D"], CGPoint(x: 1, y: -1)),
            (["S", "A"], CGPoint(x: -1, y: 1)), (["S", "D"], CGPoint(x: 1, y: 1))
        ] {
            let before = injector.events.count
            for key in keys { dispatcher.dispatch(key: key, pressed: true) }
            await injector.settle(until: before + 2)  // the neutral center, then the move
            let p = try #require(injector.events.last?.point)
            let length = hypot(vector.x, vector.y)
            #expect(abs(p.x - (center.x + radius * vector.x / length)) < 0.000001)
            #expect(abs(p.y - (center.y + radius * vector.y / length)) < 0.000001)
            for key in keys { dispatcher.dispatch(key: key, pressed: false) }
            #expect(injector.events.last?.phase == .ended)
        }
        let before = injector.events.count
        dispatcher.dispatch(key: "W", pressed: true)
        await injector.settle(until: before + 2)
        dispatcher.dispatch(key: "D", pressed: true)
        dispatcher.dispatch(key: "D", pressed: false)
        #expect(injector.events.last?.point.x == center.x)
        dispatcher.setWalking(true)
        #expect(abs(try #require(injector.events.last?.point.y) - (center.y - radius * 0.35)) < 0.000001)
        dispatcher.invalidateAll()
    }

    @Test("Resizing never shifts a measured neutral center sideways to fit a larger drag circle")
    func originNeverMovesForRadius() async throws {
        let injector = RecordingInjector(), dispatcher = ActionDispatcher()
        let calibration = try #require(JoystickCalibration(center: CGPoint(x: 40, y: 350),
            edge: CGPoint(x: 76, y: 350), width: 1000, height: 500))
        dispatcher.add(KeyJoystickAction(element: JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
            transform: .init(size: 20, xCoord: 0.2, yCoord: 0.75), calibration: calibration),
            metrics: ScreenMetrics(bounds: injector.screenBounds), injector: injector, dispatcher: dispatcher))
        dispatcher.dispatch(key: "W", pressed: true)
        await injector.settle(until: 2)
        for size in [CGSize(width: 1376, height: 1032), CGSize(width: 2195, height: 1143),
                     CGSize(width: 3440, height: 1440), CGSize(width: 240, height: 800)] {
            injector.screenBounds.size = size
            let before = injector.events.count
            dispatcher.resize(to: ScreenMetrics(bounds: injector.screenBounds))
            await injector.settle(until: before + 3)  // ended, then a new neutral center and its move
            let resumed = Array(injector.events[before...])
            #expect(resumed.map(\.phase) == [.ended, .began, .moved])
            let origin = try #require(resumed.first { $0.phase == .began }?.point)
            // The left-anchored measured center keeps its distance from the left edge in heights (40 px at 500
            // high) on screens at least as wide as the 2:1 measurement; narrower, it also keeps its share of the
            // width (KeymapCanvas scaleInHeights), as every control does.
            let scale = min(1, (size.width / size.height) / 2)
            #expect(abs(origin.x - 40 * size.height / 500 * scale) < 0.000001)
            #expect(abs(try #require(resumed.last?.point.x) - origin.x) < 0.000001)
            #expect(try #require(resumed.last?.point.y) < origin.y)
        }
        dispatcher.dispatch(key: "W", pressed: false)
        #expect(injector.events.last?.phase == .ended)
    }

    @Test("Calibration persists through encoding and fitting; malformed measurements are rejected")
    func persistenceAndValidation() throws {
        let calibration = try #require(JoystickCalibration(center: CGPoint(x: 160, y: 390),
            edge: CGPoint(x: 210, y: 390), width: 1000, height: 500))
        var map = KeymappingData(bundleIdentifier: "game")
        map.mulgAspectRatio = 2
        map.joystickModel = [JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
            transform: .init(size: 20, xCoord: 0.2, yCoord: 0.75), calibration: calibration)]
        let reloaded = try PropertyListDecoder().decode(KeymappingData.self, from: PropertyListEncoder().encode(map))
        #expect(reloaded == map)
        #expect(reloaded.fitted(toWidth: 1376, height: 1032).joystickModel[0].calibration == calibration)
        #expect(JoystickCalibration(center: CGPoint(x: 160, y: 390), edge: CGPoint(x: 160, y: 390),
            width: 1000, height: 500) == nil)
        #expect(JoystickCalibration(center: CGPoint(x: CGFloat.nan, y: 390), edge: CGPoint(x: 210, y: 390),
            width: 1000, height: 500) == nil)
        #expect(JoystickCalibration(center: CGPoint(x: 160, y: 390), edge: CGPoint(x: 950, y: 390),
            width: 1000, height: 500) == nil)
    }

    @Test("Manual joystick repositioning clears calibration without discarding other keymap settings")
    func editorPositionOverridesCalibration() throws {
        var map = KeymappingData(bundleIdentifier: "game")
        let calibration = try #require(JoystickCalibration(center: CGPoint(x: 160, y: 390),
            edge: CGPoint(x: 210, y: 390), width: 1000, height: 500))
        map.joystickModel = [JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
            transform: calibration.transform, calibration: calibration)]
        var model = KeymapEditorModel(keymap: map)
        #expect(!model.hasChanges)
        let id = try #require(model.elements.first?.id)
        model.select(id)
        model.moveSelected(by: CGVector(dx: 0.02, dy: 0.02))
        #expect(model.keymap().joystickModel[0].calibration == nil)
        #expect(abs(model.keymap().joystickModel[0].transform.xCoord - 0.18) < 0.000001)
    }
}
@MainActor private final class DelayedBeginInjector: TouchInjecting {
    var delivered = false
    var screenBounds: CGRect { CGRect(x: 0, y: 0, width: 100, height: 100) }
    func touch(_ id: inout Int?, at point: CGPoint, phase: TouchPhase) {}
    func hasDeliveredBegin(_ id: Int) -> Bool { delivered }
}

@Suite("Waiting for a touch to land") @MainActor
struct BeginWaitTests {
    @Test("Without delivery callbacks, the wait polls until UIKit has the touch or times out")
    func pollingFallback() async {
        let injector = DelayedBeginInjector()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            injector.delivered = true
        }
        #expect(await injector.waitForBegin(1, timeout: .seconds(1)))
        injector.delivered = false
        let start = ContinuousClock.now
        #expect(!(await injector.waitForBegin(1, timeout: .milliseconds(40))))
        #expect(ContinuousClock.now - start >= .milliseconds(40))
    }
}
