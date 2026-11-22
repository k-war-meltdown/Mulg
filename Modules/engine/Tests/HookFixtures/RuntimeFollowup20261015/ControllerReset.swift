import Foundation
import CoreGraphics
import Synchronization
enum ControllerStickSettings {}
enum StickResponse { static func shape(x: Double, y: Double, settings: Int) -> (x: Double, y: Double) { (x,y) } }
final class Controller: NSObject {}
@MainActor final class Dispatcher {
    func hasMapping(for: String) -> Bool { false }
    func layer(heldBy: String) -> Int? { nil }
    func withInputTransaction(_ body: () -> Void) { body() }
    func dispatch(key: String, x: CGFloat, y: CGFloat) {}
}
@MainActor final class Input {
    final class Device {
        var connected = true, dpadX: Float = 0, dpadY: Float = 0
        var buttons: Set<String> = [], sticks: [String: CGVector] = [:], rawSticks: [String: CGVector] = [:]
        let lifecycle = Mutex((generation: UInt64(1), enabled: true))
    }
    enum Sample { case button(String, Bool), stick(String, Float, Float), dpad(Float, Float, [Sample?]); indirect case aliased(Sample, [String]) }
    var active = true, releasingInputs = false, sticks = 0
    var devices: [ObjectIdentifier: Device] = [:], heldButtons: Set<String> = [], tiltedSticks: Set<String> = []
    var cameraSticks: [String: CGVector] = [:], stickOwners: [String: ObjectIdentifier] = [:], motionOwner: ObjectIdentifier?
    var pollTask: Task<Void, Never>?, onMotion: ((Double, Double, Double) -> Void)?, editorSink: ((String) -> Void)?
    var callback: ((String, Bool) -> Void)?
    let dispatcher = Dispatcher()
    func dispatchButton(_ name: String, pressed: Bool) { callback?(name, pressed) }
    func reapplyStick(_ name: String) {}
    // __PRODUCTION__
}
Task { @MainActor in
    let input = Input(), controller = Controller(), device = Input.Device()
    let identity = ObjectIdentifier(controller); input.devices[identity] = device
    input.callback = { _, pressed in if pressed { input.releaseEverything() } }
    input.changed(.dpad(1, 0, [.button("Right", true), nil, nil, nil]), controller: identity, generation: 1)
    assert(device.dpadX == 0 && device.buttons.isEmpty && input.heldButtons.isEmpty, "A reset must not inherit the old D-pad axes")
    device.buttons = ["A"]; input.heldButtons = ["A"]
    var releases = 0
    input.callback = { _, pressed in
        if !pressed { releases += 1; if releases < 4 { input.releaseEverything() } }
    }
    input.releaseEverything()
    assert(releases == 1, "Cleanup callbacks must not recursively release the same physical input")
    print("PASS: physical-controller resets keep cleared axes and release each hold once")
    exit(0)
}
dispatchMain()
