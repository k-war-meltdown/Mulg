import CoreGraphics
import Foundation
import GameController
import MulgContracts
import MulgControlsHooks
import MulgEngine
import Testing
@testable import MulgControls

@MainActor private final class CaptureEnvironment: InputEnvironment {
    var hidden = false
    var menuVisible = true
    var captureChanges: [Bool] = []
    func cursorPoint() -> CGPoint? { nil }
    func setCursorHidden(_ hidden: Bool) {
        guard self.hidden != hidden else { return }
        self.hidden = hidden
        captureChanges.append(hidden)
    }
    var isFullscreen: Bool { true }
    func setMenuBarVisible(_ visible: Bool) { menuVisible = visible }
}

@Suite("Live input and cursor ownership", .serialized) @MainActor
struct LiveInputTests {
    private func router(_ settings: GameSettings, environment: CaptureEnvironment,
                        movement: @escaping ActionDispatcher.DirectionHandler = { _, _ in }) -> InputRouter {
        let dispatcher = ActionDispatcher()
        dispatcher.register(key: KeymapNames.mouseMove, priority: .camera, handler: movement)
        return InputRouter(settings: settings, dispatcher: dispatcher, hotkeys: HotkeyCenter(),
            events: EventBus(), environment: environment, fakeMouse: FakeMouseAction(injector: RecordingInjector()), menuKeys: [])
    }

    @Test("Middle click owns the cursor switch even when a gameplay binding uses that button")
    func middleClickTogglesCursor() {
        var settings = GameSettings()
        settings.mulg.controls.cursorKeyBehaviour = .hold
        let environment = CaptureEnvironment()
        let input = router(settings, environment: environment)
        input.start()
        #expect(input.mode == .camera && environment.hidden)
        #expect(input.mouseButton(2, pressed: true) && input.mouseButton(2, pressed: false))
        #expect(input.mode == .cursor && !environment.hidden)  // stays shown after the release
        #expect(input.mouseButton(2, pressed: true) && input.mouseButton(2, pressed: false))
        #expect(input.mode == .camera && environment.hidden)

        var presses: [Bool] = []
        input.dispatcher.register(key: KeymapKeyNames.name(forMouseButton: 2)) { presses.append($0) }
        _ = input.mouseButton(2, pressed: true); _ = input.mouseButton(2, pressed: false)
        #expect(presses.isEmpty && input.mode == .cursor && !environment.hidden)
        _ = input.modifier(code: 0x3A, pressed: true, flags: 0)
        _ = input.modifier(code: 0x3A, pressed: false, flags: 0)
        _ = input.mouseMoved(dx: 100, dy: 20); input.frameStarts()
        input.keymapRebuilt()
        #expect(input.mode == .camera && environment.hidden)
        #expect(environment.captureChanges == [true, false, true, false, true])
        input.focusLost()
    }

    @Test("An Alt tap still switches after a web view or keymap rebuild flickers mid-tap, and a release in text input never sticks")
    func altTapSurvivesFlicker() {
        let environment = CaptureEnvironment()
        let input = router(GameSettings(), environment: environment)
        input.start()
        defer { input.focusLost() }
        #expect(input.mode == .camera)
        _ = input.modifier(code: 0x3A, pressed: true, flags: 0)
        input.setNativeInterfaceActive(true); input.setNativeInterfaceActive(false)
        input.prepareForKeymapChange()
        _ = input.modifier(code: 0x3A, pressed: false, flags: 0)
        #expect(input.mode == .cursor && !environment.hidden)
        // Released while a text field owns input: the next taps still work.
        _ = input.modifier(code: 0x3A, pressed: true, flags: 0)
        input.textInputBegan()
        _ = input.modifier(code: 0x3A, pressed: false, flags: 0)
        input.textInputEnded()
        _ = input.modifier(code: 0x3A, pressed: true, flags: 0)
        _ = input.modifier(code: 0x3A, pressed: false, flags: 0)
        #expect(input.mode == .camera && environment.hidden)
    }

    @Test("With cursorKeySwitchesCamera off, Alt and middle click only switch the edge lock and never mouse look")
    func edgeLockLeavesMouseLookAlone() {
        var settings = GameSettings()
        settings.mulg.controls.cursorKeySwitchesCamera = false
        let environment = CaptureEnvironment()
        var views = 0
        let input = router(settings, environment: environment) { _, _ in views += 1 }
        input.start()
        defer { input.focusLost() }
        #expect(input.mode == .camera && environment.hidden)
        _ = input.modifier(code: 0x3A, pressed: true, flags: 0)
        _ = input.modifier(code: 0x3A, pressed: false, flags: 0)
        #expect(input.mode == .camera && environment.hidden)
        #expect(input.mouseButton(2, pressed: true) && input.mouseButton(2, pressed: false))
        #expect(input.mode == .camera && environment.hidden)
        _ = input.mouseMoved(dx: 3, dy: 1); input.frameStarts()
        #expect(views > 0, "Mouse look keeps working")
        #expect(environment.captureChanges == [true])
    }

    @Test("Combat holds keep the view finger; after release real motion reacquires the camera")
    func viewFingerSurvivesTapsAndPauses() async throws {
        let dispatcher = ActionDispatcher(), injector = RecordingInjector()
        let metrics = ScreenMetrics(bounds: injector.screenBounds)
        let environment = CaptureEnvironment()
        dispatcher.add(CameraAction(element: MouseAreaElement(transform: .init(size: 25, xCoord: 0.5, yCoord: 0.5)),
            metrics: metrics, injector: injector, dispatcher: dispatcher, liveMetrics: { metrics }))
        var attack = ButtonElement(keyCode: -1, keyName: "", transform: .init(size: 10, xCoord: 0.83, yCoord: 0.79))
        attack.tapDurationMilliseconds = 60
        dispatcher.add(ButtonAction(element: attack, metrics: metrics, injector: injector, dispatcher: dispatcher))
        dispatcher.add(ButtonAction(element: .init(keyCode: 20, keyName: "Q", transform: .init(size: 8, xCoord: 0.9, yCoord: 0.85)),
            metrics: metrics, injector: injector, dispatcher: dispatcher))
        let input = InputRouter(settings: GameSettings(), dispatcher: dispatcher, hotkeys: HotkeyCenter(),
            events: EventBus(), environment: environment, fakeMouse: FakeMouseAction(injector: injector), menuKeys: [])
        input.start()
        defer { input.focusLost() }
        #expect(input.mode == .camera)
        _ = input.mouseMoved(dx: 4, dy: 1); input.frameStarts()
        let cameraID = try #require(injector.events.first?.id)
        // The mouse rests longer than the old 0.5 s idle lift, then attack and skill are tapped.
        try await Task.sleep(for: .milliseconds(700))
        #expect(input.mouseButton(0, pressed: true) && input.mouseButton(0, pressed: false))
        #expect(input.key(code: 0x0C, pressed: true, isRepeat: false, flags: 0))
        _ = input.mouseMoved(dx: 3, dy: 0); input.frameStarts()
        #expect(input.key(code: 0x0C, pressed: false, isRepeat: false, flags: 0))
        try await Task.sleep(for: .milliseconds(150))
        _ = input.mouseMoved(dx: 5, dy: -2); input.frameStarts()
        let camera = injector.events.filter { $0.id == cameraID }.map(\.phase)
        #expect(camera == [.began, .moved, .moved, .ended], "Keep the finger during combat, renew after the contacts finish")
        let renewedID = try #require(injector.events.last?.id)
        #expect(renewedID != cameraID)
        let buttons = injector.events.filter { $0.id != cameraID && $0.id != renewedID }.map(\.phase)
        #expect(buttons == [.began, .began, .ended, .ended], "Attack and skill use their own touches")
        #expect(injector.events.filter { $0.id == renewedID }.map(\.phase) == [.began, .moved])

        // Option lifts it; back in camera mode (middle click) the next movement is a new finger.
        _ = input.modifier(code: 0x3A, pressed: true, flags: 0)
        _ = input.modifier(code: 0x3A, pressed: false, flags: 0)
        #expect(input.mode == .cursor)
        #expect(injector.events.last?.id == renewedID && injector.events.last?.phase == .ended)
        #expect(input.mouseButton(2, pressed: true) && input.mouseButton(2, pressed: false))
        _ = input.mouseMoved(dx: 2, dy: 0); input.frameStarts()
        let second = try #require(injector.events.last?.id)
        #expect(second != renewedID && input.mode == .camera)
        // Middle click lifts it too.
        #expect(input.mouseButton(2, pressed: true) && input.mouseButton(2, pressed: false))
        #expect(input.mode == .cursor)
        #expect(injector.events.last?.id == second && injector.events.last?.phase == .ended)
    }

    @Test("Camera movement and a held R aiming drag work in parallel without cursor changes")
    func cameraAndSkillDoNotStealEachOthersMouse() throws {
        let dispatcher = ActionDispatcher(), injector = RecordingInjector()
        let metrics = ScreenMetrics(bounds: injector.screenBounds)
        let environment = CaptureEnvironment()
        let camera = CameraAction(element: MouseAreaElement(transform: .init(size: 25, xCoord: 0.5, yCoord: 0.5)),
            metrics: metrics, injector: injector, dispatcher: dispatcher, liveMetrics: { metrics })
        dispatcher.add(camera)
        dispatcher.add(DraggableButtonAction(element: .init(keyCode: 21, keyName: "R",
            transform: .init(size: 5, xCoord: 0.85, yCoord: 0.8)), metrics: metrics,
            injector: injector, dispatcher: dispatcher))
        var buttons: [Bool] = []
        dispatcher.register(key: "F") { buttons.append($0) }
        let input = InputRouter(settings: GameSettings(), dispatcher: dispatcher, hotkeys: HotkeyCenter(),
            events: EventBus(), environment: environment, fakeMouse: FakeMouseAction(injector: injector), menuKeys: [])
        input.start()
        defer { input.focusLost() }
        #expect(dispatcher.dispatchMouseView(x: 1, y: 0))
        let cameraID = injector.events.first?.id
        #expect(input.key(code: 0x0F, pressed: true, isRepeat: false, flags: 0)) // R
        #expect(input.key(code: 0x03, pressed: true, isRepeat: false, flags: 0)) // F
        _ = input.mouseMoved(dx: 2, dy: 1); input.frameStarts()
        #expect(input.mode == .camera && environment.hidden)
        let cameraEvents = injector.events.filter { $0.id == cameraID }
        #expect(cameraEvents.map(\.phase) == [.began, .moved, .moved])
        #expect(injector.events.filter { $0.id != cameraID }.map(\.phase) == [.began, .moved])
        #expect(input.key(code: 0x0F, pressed: false, isRepeat: false, flags: 0))
        #expect(input.key(code: 0x03, pressed: false, isRepeat: false, flags: 0))
        #expect(buttons == [true, false])
        _ = input.mouseMoved(dx: 1, dy: 0); input.frameStarts()
        #expect(injector.events.filter { $0.id == cameraID }.map(\.phase) == [.began, .moved, .moved, .moved])
        _ = input.modifier(code: 0x3A, pressed: true, flags: 0)
        _ = input.modifier(code: 0x3A, pressed: false, flags: 0)
        #expect(input.mode == .cursor && !environment.hidden)
        #expect(injector.events.last?.id == cameraID && injector.events.last?.phase == .ended)
        let count = injector.events.count
        _ = input.mouseMoved(dx: 3, dy: 1); input.frameStarts()
        #expect(injector.events.count == count, "Cursor motion must not continue mouse-look")
    }

    @Test("A held pointer layer cannot interrupt the base camera or change the cursor choice")
    func layerKeysKeepTheViewIndependent() {
        let dispatcher = ActionDispatcher(), injector = RecordingInjector()
        let metrics = ScreenMetrics(bounds: injector.screenBounds)
        let cameraElement = MouseAreaElement(transform: .init(size: 25, xCoord: 0.5, yCoord: 0.5))
        dispatcher.add(CameraAction(element: cameraElement, metrics: metrics, injector: injector,
            dispatcher: dispatcher, liveMetrics: { metrics }))
        dispatcher.beginLayer(1, holdKey: "Q")
        var presses: [Bool] = []
        dispatcher.register(key: "R") { presses.append($0) }
        dispatcher.endLayer()
        var map = KeymappingData(bundleIdentifier: "custom.game")
        map.mouseAreaModel = [cameraElement]
        var layer = KeymapLayer(name: "Skills", holdKeyCode: 20, holdKeyName: "Q")
        layer.mulgControlProfile = .init(interactionStyle: .pointer)
        map.mulgLayers = [layer]
        let environment = CaptureEnvironment()
        let input = InputRouter(settings: GameSettings(), dispatcher: dispatcher, hotkeys: HotkeyCenter(),
            events: EventBus(), environment: environment, fakeMouse: FakeMouseAction(injector: injector), menuKeys: [])
        input.keymapRebuilt(map); input.start()
        defer { input.focusLost() }
        _ = dispatcher.dispatchMouseView(x: 1, y: 0)
        let cameraID = injector.events.first?.id
        #expect(input.key(code: 0x0C, pressed: true, isRepeat: false, flags: 0)) // Q
        #expect(dispatcher.activeLayer == 1 && input.mode == .camera && environment.hidden)
        #expect(input.key(code: 0x0F, pressed: true, isRepeat: false, flags: 0))
        _ = dispatcher.dispatchMouseView(x: 2, y: 0)
        #expect(input.key(code: 0x0F, pressed: false, isRepeat: false, flags: 0))
        #expect(input.key(code: 0x0C, pressed: false, isRepeat: false, flags: 0))
        #expect(presses == [true, false] && dispatcher.activeLayer == 0)
        _ = dispatcher.dispatchMouseView(x: 1, y: 0)
        #expect(injector.events.filter { $0.id == cameraID }.map(\.phase) == [.began, .moved, .moved, .moved])
        _ = input.modifier(code: 0x3A, pressed: true, flags: 0); _ = input.modifier(code: 0x3A, pressed: false, flags: 0)
        #expect(input.mode == .cursor && !environment.hidden)
        _ = input.key(code: 0x0C, pressed: true, isRepeat: false, flags: 0)
        _ = input.key(code: 0x0C, pressed: false, isRepeat: false, flags: 0)
        #expect(input.mode == .cursor && !environment.hidden)
    }

    @Test("An analog mouse-view binding receives each motion once, including with a held drag")
    func analogViewHasNoDuplicateDelivery() {
        let dispatcher = ActionDispatcher()
        var view = 0, drag = 0
        dispatcher.register(key: KeymapNames.mouseMove) { _, _ in view += 1 }
        #expect(dispatcher.dispatchMouseView(x: 1, y: 0))
        let registration = dispatcher.register(key: KeymapNames.mouseMove, priority: .draggable) { _, _ in drag += 1 }
        #expect(dispatcher.dispatchMouseView(x: 1, y: 0))
        #expect(view == 2 && drag == 1)
        dispatcher.unregister(registration: registration)
        #expect(dispatcher.dispatchMouseView(x: 1, y: 0))
        #expect(view == 3 && drag == 1)
    }

    @Test("A view mapped in a layer stays available without holding its gameplay layer key")
    func layerOnlyCameraIsAnIndependentView() {
        let dispatcher = ActionDispatcher(), injector = RecordingInjector()
        let metrics = ScreenMetrics(bounds: injector.screenBounds)
        let camera = MouseAreaElement(transform: .init(size: 25, xCoord: 0.5, yCoord: 0.5))
        dispatcher.beginLayer(1, holdKey: "Q")
        dispatcher.add(CameraAction(element: camera, metrics: metrics, injector: injector,
            dispatcher: dispatcher, liveMetrics: { metrics }))
        dispatcher.endLayer()
        var map = KeymappingData(bundleIdentifier: "custom.game")
        var layer = KeymapLayer(name: "View", holdKeyCode: 20, holdKeyName: "Q")
        layer.mouseAreaModel = [camera]; map.mulgLayers = [layer]
        let environment = CaptureEnvironment()
        let input = InputRouter(settings: GameSettings(), dispatcher: dispatcher, hotkeys: HotkeyCenter(),
            events: EventBus(), environment: environment, fakeMouse: FakeMouseAction(injector: injector), menuKeys: [])
        input.keymapRebuilt(map); input.start()
        defer { input.focusLost() }
        #expect(input.mode == .camera && environment.hidden && dispatcher.activeLayer == 0)
        _ = input.mouseMoved(dx: 1, dy: 0); input.frameStarts()
        #expect(injector.events.map(\.phase) == [.began, .moved])
    }

    @Test("Held/repeated skill keys and ordinary mouse clicks do not cancel the Option cursor switch")
    func optionWorksAlongsideGameplayInputs() {
        let environment = CaptureEnvironment(), input = router(GameSettings(), environment: environment)
        var keys: [Bool] = [], clicks: [Bool] = []
        input.dispatcher.register(key: "R") { keys.append($0) }
        input.dispatcher.register(key: KeymapNames.leftMouseButton) { clicks.append($0) }
        input.start()
        defer { input.focusLost() }
        _ = input.modifier(code: 0x3A, pressed: true, flags: 0)
        #expect(input.key(code: 0x0F, pressed: true, isRepeat: false, flags: 0))
        #expect(input.key(code: 0x0F, pressed: true, isRepeat: true, flags: 0))
        #expect(input.mouseButton(0, pressed: true) && input.mouseButton(0, pressed: false))
        #expect(input.mode == .camera && environment.hidden)
        _ = input.modifier(code: 0x3A, pressed: false, flags: 0)
        #expect(input.mode == .cursor && !environment.hidden)
        #expect(input.key(code: 0x0F, pressed: false, isRepeat: false, flags: 0))
        #expect(keys == [true, false] && clicks == [true, false])
    }

    @Test func focusLossReleasesCaptureAndDoesNotWarpUntilCameraFocusReturns() {
        let environment = CaptureEnvironment(), input = router(GameSettings(), environment: environment)
        input.start()
        #expect(environment.hidden && !environment.menuVisible)
        input.focusLost()
        let changes = environment.captureChanges
        #expect(!environment.hidden && environment.menuVisible)
        input.setEditorOpen(true)
        input.setEditorOpen(false)
        #expect(!environment.hidden && environment.captureChanges == changes)
        input.focusGained()
        #expect(environment.hidden && environment.captureChanges == changes + [true])
        input.textInputBegan()
        input.focusLost(); input.focusGained()
        #expect(!environment.hidden)
        input.textInputEnded()
        #expect(environment.hidden)
        input.setEditorOpen(true)
        input.focusLost(); input.focusGained()
        #expect(!environment.hidden)
        input.focusLost()
    }

    @Test func liveMouseSensitivityAndStickCurveReachSubsequentMovement() throws {
        var settings = GameSettings(), movement: [CGFloat] = []
        settings.sensitivity = 100
        let input = router(settings, environment: CaptureEnvironment()) { x, _ in movement.append(x) }
        _ = input.mouseMoved(dx: 10, dy: 0); input.frameStarts()
        #expect(abs((movement.last ?? 0) - 6) < 0.001)
        settings.sensitivity = 200
        input.updateTuning(settings)
        _ = input.mouseMoved(dx: 10, dy: 0); input.frameStarts()
        #expect(abs((movement.last ?? 0) - 12) < 0.001)
        var curve = StickCurveSettings()
        curve.sensitivity = 0.1; curve.exponent = 1; curve.deadzone = 0
        let virtual = VirtualController(bindings: [], stickCurve: curve)
        input.virtualController = virtual
        virtual.mouseMoved(dx: 1, dy: 0)
        let pad = try #require(virtual.controller.extendedGamepad)
        #expect(abs(pad.rightThumbstick.xAxis.value - 0.1) < 0.001)
        settings.mulg.controls.mouseToStick = curve
        settings.mulg.controls.mouseToStick.sensitivity = 0.2
        input.updateTuning(settings)
        #expect(pad.rightThumbstick.xAxis.value == 0)
        virtual.mouseMoved(dx: 1, dy: 0)
        #expect(abs(pad.rightThumbstick.xAxis.value - 0.2) < 0.001)
        input.focusLost()
        mulg_controller_set_virtual(nil)
    }

    @Test func mouseAndControllerGyroUseLivePitchAndYawTuning() {
        var settings = GameSettings()
        settings.mulg.controls.gyro.source = .mouse
        let input = router(settings, environment: CaptureEnvironment())
        mulg_motion_recenter()
        mulg_motion_set_steady_rate(0, 0, 0)
        defer { mulg_motion_set_steady_rate(0, 0, 0) }
        _ = input.mouseMoved(dx: 10, dy: 10); input.frameStarts()
        let before = mulg_motion_step(0.01)
        settings.mulg.controls.gyro.mouseYawSensitivity *= 2
        settings.mulg.controls.gyro.mousePitchSensitivity *= 3
        settings.mulg.controls.gyro.invertPitch = true
        input.updateTuning(settings)
        _ = input.mouseMoved(dx: 10, dy: 10); input.frameStarts()
        let after = mulg_motion_step(0.01)
        #expect(abs(after.rateX - before.rateX * 2) < 0.001)
        #expect(abs(after.rateY + before.rateY * 3) < 0.001)
        input.controllerMotion(x: 1, y: 2, z: 3)
        #expect(mulg_motion_step(0.01).rateY == -2)
        settings.mulg.controls.gyro.invertPitch = false
        input.updateTuning(settings)
        input.controllerMotion(x: 1, y: 2, z: 3)
        #expect(mulg_motion_step(0.01).rateY == 2)
        input.focusLost()
    }

    @Test func heldGyroKeysUseLiveSpeedWithoutChangingTheirStartupSource() {
        var settings = GameSettings()
        settings.mulg.controls.gyro.source = .keys
        let input = router(settings, environment: CaptureEnvironment())
        mulg_motion_recenter()
        defer { mulg_motion_set_steady_rate(0, 0, 0) }
        _ = input.key(code: 0x7D, pressed: true, isRepeat: false, flags: 0)
        #expect(abs(mulg_motion_step(0.01).rateY + .pi / 2) < 0.001)
        settings.mulg.controls.gyro.keyRotationSpeed = 180
        settings.mulg.controls.gyro.invertPitch = true
        settings.mulg.controls.gyro.source = .off // Restart-only.
        input.updateTuning(settings)
        #expect(abs(mulg_motion_step(0.01).rateY - .pi) < 0.001)
        input.focusLost()
        input.updateTuning(settings)
        #expect(mulg_motion_step(0.01).rateY == 0)
    }
}
