import CoreGraphics
import Foundation
import MulgContracts
import MulgEngine
import Testing
@testable import MulgControls

@MainActor private final class RuntimeEdgeEnvironment: InputEnvironment {
    func cursorPoint() -> CGPoint? { nil }
    func setCursorHidden(_ hidden: Bool) {}
    var isFullscreen: Bool { false }
    func setMenuBarVisible(_ visible: Bool) {}
}

@MainActor private final class CancellationRecorder: TouchInjecting {
    let screenBounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
    var cancelled = 0
    var ended = 0
    private var next = 0
    func touch(_ id: inout Int?, at point: CGPoint, phase: TouchPhase) {
        if phase == .began { next += 1; id = next }
        if phase == .ended, id != nil { ended += 1; id = nil }
    }
    func cancel(_ id: inout Int?, at point: CGPoint) {
        if id != nil { cancelled += 1; id = nil }
    }
}

@Suite("Runtime input edges", .serialized) @MainActor
struct RuntimeEdgeRegressionTests {
    private func router(_ dispatcher: ActionDispatcher, injector: any TouchInjecting) -> InputRouter {
        var settings = GameSettings()
        settings.mulg.controls.walkModifierKey = "shift"
        dispatcher.register(key: KeymapNames.mouseMove, priority: .camera) { _, _ in }
        let input = InputRouter(settings: settings, dispatcher: dispatcher, hotkeys: HotkeyCenter(),
            events: EventBus(), environment: RuntimeEdgeEnvironment(),
            fakeMouse: FakeMouseAction(injector: injector), menuKeys: [])
        input.start()
        return input
    }

    @Test("Unmapped native keys keep repeats; mapped keys emit exactly two edges")
    func repeatOwnership() {
        let dispatcher = ActionDispatcher()
        let input = router(dispatcher, injector: RecordingInjector())
        defer { input.focusLost() }
        var edges: [Bool] = []
        dispatcher.register(key: "R") { edges.append($0) }
        #expect(!input.key(code: 0x03, pressed: true, isRepeat: false, flags: 0))
        #expect(!input.key(code: 0x03, pressed: true, isRepeat: true, flags: 0))
        #expect(!input.key(code: 0x03, pressed: false, isRepeat: false, flags: 0))
        #expect(input.key(code: 0x0F, pressed: true, isRepeat: false, flags: 0))
        #expect(input.key(code: 0x0F, pressed: true, isRepeat: true, flags: 0))
        #expect(input.key(code: 0x0F, pressed: false, isRepeat: false, flags: 0))
        #expect(edges == [true, false])
    }

    @Test("Walking stays active until both configured modifier keys are released")
    func twoWalkModifiers() {
        let dispatcher = ActionDispatcher(), injector = RecordingInjector()
        let input = router(dispatcher, injector: injector)
        let joystick = KeyJoystickAction(element: .init(upKeyCode: 26, rightKeyCode: 7,
            downKeyCode: 22, leftKeyCode: 4, transform: .init(size: 20, xCoord: 0.5, yCoord: 0.5)),
            metrics: injector.screenMetrics, injector: injector, dispatcher: dispatcher)
        dispatcher.add(joystick)
        defer { input.focusLost() }
        joystick.keyChanged(index: 0, pressed: true)
        _ = input.modifier(code: 0x38, pressed: true, flags: 0)
        _ = input.modifier(code: 0x3C, pressed: true, flags: 0)
        _ = input.modifier(code: 0x38, pressed: false, flags: 0)
        #expect(joystick.inputDiagnostics?["requestedY"] == 0.35)
        _ = input.modifier(code: 0x3C, pressed: false, flags: 0)
        #expect(joystick.inputDiagnostics?["requestedY"] == 1)
    }

    @Test("Overlapping cursor modifiers toggle once, after the last release")
    func twoCursorModifiers() {
        let input = router(ActionDispatcher(), injector: RecordingInjector())
        defer { input.focusLost() }
        _ = input.modifier(code: 0x3A, pressed: true, flags: 0)
        _ = input.modifier(code: 0x3D, pressed: true, flags: 0)
        _ = input.modifier(code: 0x3A, pressed: false, flags: 0)
        #expect(input.mode == .camera)
        _ = input.modifier(code: 0x3D, pressed: false, flags: 0)
        #expect(input.mode == .cursor)
    }

    @Test("Releasing one Control key does not release a chord held by the other")
    func twoControlModifiers() {
        let dispatcher = ActionDispatcher()
        let input = router(dispatcher, injector: RecordingInjector())
        defer { input.focusLost() }
        var edges: [Bool] = []
        dispatcher.register(key: "⌃R") { edges.append($0) }
        let control: UInt = 1 << 18
        _ = input.modifier(code: 0x3B, pressed: true, flags: control)
        _ = input.modifier(code: 0x3E, pressed: true, flags: control)
        _ = input.key(code: 0x0F, pressed: true, isRepeat: false, flags: control)
        _ = input.modifier(code: 0x3B, pressed: false, flags: control)
        #expect(edges == [true])
        _ = input.modifier(code: 0x3E, pressed: false, flags: 0)
        #expect(edges == [true, false])
        _ = input.key(code: 0x0F, pressed: false, isRepeat: false, flags: 0)
        #expect(edges == [true, false])
    }

    @Test("Native cancellation cancels both fingers without completing the gesture")
    func cancelledGestures() {
        let injector = CancellationRecorder()
        let gestures = TrackpadGestures(injector: injector) { injector.screenMetrics }
        gestures.magnify(by: 0.2, phase: 1, at: nil)
        gestures.rotate(by: 10, phase: 1, at: nil)
        gestures.magnify(by: 0.4, phase: 4, at: nil)
        #expect(!gestures.isActive && injector.cancelled == 2 && injector.ended == 0)
        gestures.magnify(by: 0, phase: 1, at: nil)
        gestures.rotate(by: 0, phase: 1, at: nil)
        gestures.magnify(by: 0, phase: 3, at: nil)
        #expect(gestures.isActive)
        gestures.rotate(by: 0, phase: 3, at: nil)
        #expect(!gestures.isActive && injector.ended == 2)
    }
}
