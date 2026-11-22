import Foundation
enum VirtualControllerElement: CaseIterable {
    case leftStickUp, leftStickDown, leftStickLeft, leftStickRight
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger, leftThumbstickButton, rightThumbstickButton
    case buttonA, buttonB, buttonX, buttonY, buttonMenu, buttonOptions
}
struct Binding {
    var element: VirtualControllerElement
    var chord: [VirtualControllerElement]?
    var toggle: Bool?, alternateWhile: VirtualControllerElement?, alternateElement: VirtualControllerElement?
    var menuElement: VirtualControllerElement?, releaseToggles: [VirtualControllerElement]?
}
struct KeyStick { mutating func set(_ element: VirtualControllerElement, pressed: Bool) {} }
struct StickCurve { var settings: Int }
@MainActor final class Virtual {
    var definitions: [Int: Binding] = [1: Binding(element: .buttonB, chord: [.buttonA])]
    var heldInputs: [Int: [VirtualControllerElement]] = [:]
    var physicalKeys: Set<Int> = [], appliedElements: Set<VirtualControllerElement> = []
    var inputGeneration: UInt64 = 0, releasingAll = false
    var keyStick = KeyStick(), dpadState = KeyStick(), rightStick = StickCurve(settings: 0)
    var decayTask: Task<Void, Never>?, mouseUpdatedSinceFrame = false, lastFrameTime: ContinuousClock.Instant?
    var hardware: [VirtualControllerElement: Bool] = [:]
    var onSet: ((VirtualControllerElement, Float) -> Void)?
    func applyLeftStick() {}
    func applyRightStick() {}
    func applyDpad() {}
    func setButton(_ element: VirtualControllerElement, value: Float, updateDpad: Bool = true) {
        hardware[element] = value != 0
        onSet?(element, value)
    }
    // __PRODUCTION__
}
Task { @MainActor in
    let controller = Virtual()
    controller.onSet = { element, value in
        if element == .buttonA && value == 1 { controller.releaseAll() }
    }
    _ = controller.key(code: 1, pressed: true)
    assert(!controller.hardware.values.contains(true), "A cancelled chord must not publish its remaining buttons")
    assert(controller.appliedElements.isEmpty && controller.heldInputs.isEmpty)
    controller.onSet = nil
    _ = controller.key(code: 1, pressed: true)
    assert(controller.hardware[.buttonA] == true && controller.hardware[.buttonB] == true)
    _ = controller.key(code: 1, pressed: false)
    assert(!controller.hardware.values.contains(true))
    print("PASS: reentrant reset stops the old chord; later presses still work")
    exit(0)
}
dispatchMain()
