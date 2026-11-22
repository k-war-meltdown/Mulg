import Foundation
import CoreGraphics
enum VirtualControllerElement {
    case buttonA, buttonB, buttonX, buttonY, leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case dpadUp, dpadDown, dpadLeft, dpadRight, leftThumbstickButton, rightThumbstickButton, buttonMenu, buttonOptions
    case leftStickUp, leftStickDown, leftStickLeft, leftStickRight
}
@MainActor final class Button {
    var value: Float = 0, callback: ((Float) -> Void)?
    func setValue(_ value: Float) { self.value = value; callback?(value) }
}
@MainActor final class Pad {
    let buttonA = Button(), buttonB = Button(), buttonX = Button(), buttonY = Button()
    let leftShoulder = Button(), rightShoulder = Button(), leftTrigger = Button(), rightTrigger = Button(), buttonMenu = Button()
    var leftThumbstickButton: Button? = Button(), rightThumbstickButton: Button? = Button(), buttonOptions: Button? = Button()
}
@MainActor final class Snapshot { var extendedGamepad: Pad? = Pad() }
@MainActor final class Native { var value: CGFloat = 0; func setValue(_ value: CGFloat, forButtonElement: String) { self.value = value } }
struct Dpad { mutating func set(_ element: VirtualControllerElement, pressed: Bool) {} }
@MainActor final class Virtual {
    let snapshotController = Snapshot()
    var systemDevice: Native? = Native(), nativeConnected = true, inputGeneration: UInt64 = 0, dpadState = Dpad()
    func applyDpad() {}
    func nativeButtonName(_ element: VirtualControllerElement) -> String? { "button" }
    func reset() { inputGeneration += 1; setButton(.buttonA, value: 0) }
    // __PRODUCTION__
}
Task { @MainActor in
    let controller = Virtual()
    controller.snapshotController.extendedGamepad!.buttonA.callback = { value in if value == 1 { controller.reset() } }
    controller.setButton(.buttonA, value: 1)
    assert(controller.snapshotController.extendedGamepad!.buttonA.value == 0 && controller.systemDevice!.value == 0,
        "A snapshot callback reset must not be overwritten by the old native-device write")
    controller.snapshotController.extendedGamepad!.buttonA.callback = nil
    controller.setButton(.buttonA, value: 1)
    assert(controller.systemDevice!.value == 1)
    print("PASS: reentrant snapshot callbacks cannot replay stale input to the connected device")
    exit(0)
}
dispatchMain()
