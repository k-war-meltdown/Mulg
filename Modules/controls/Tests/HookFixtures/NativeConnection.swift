import Foundation
import CoreGraphics

let GCInputLeftThumbstick = "Left", GCInputRightThumbstick = "Right", GCInputDirectionPad = "Dpad"
let GCInputButtonA = "A", GCInputButtonB = "B", GCInputButtonX = "X", GCInputButtonY = "Y"
let GCInputLeftShoulder = "LS", GCInputRightShoulder = "RS", GCInputLeftTrigger = "LT", GCInputRightTrigger = "RT"
let GCInputButtonMenu = "Menu", GCInputButtonOptions = "Options"
@MainActor final class GCController { var extendedGamepad: Int? = 1 }
@MainActor final class GCVirtualController {
    final class Configuration { var isHidden = false; var elements: Set<String> = [] }
    static var attempts = 0, disconnects = 0
    var controller: GCController?
    init(configuration: Configuration) {}
    func connect() async throws {
        Self.attempts += 1
        if Self.attempts > 1 { controller = GCController() }
        await Task.yield()
    }
    func disconnect() { Self.disconnects += 1; controller = nil }
}
var published: GCController?
@MainActor func mulg_controller_set_virtual(_ controller: GCController?) { published = controller }
enum VirtualControllerElement: CaseIterable { case buttonA }
@MainActor final class VirtualController {
    var systemDevice: GCVirtualController?
    var nativeConnectionTask: Task<Void, Never>?
    var nativeConnected = false
    var deviceConnectionError: String?
    var appliedElements: Set<VirtualControllerElement> = [.buttonA]
    var transferredButton = false
    func applyLeftStick(force: Bool) {}
    func applyRightStick() {}
    func applyDpad(force: Bool) {}
    func setButton(_ element: VirtualControllerElement, value: Int, updateDpad: Bool) { transferredButton = value == 1 }
    // __PRODUCTION__
}
Task { @MainActor in
    let controller = VirtualController()
    controller.connectNativeDevice()
    for _ in 0..<1000 where GCVirtualController.disconnects == 0 { await Task.yield() }
    assert(controller.deviceConnectionError != nil && controller.systemDevice == nil && controller.nativeConnectionTask == nil)
    controller.connectNativeDevice()
    for _ in 0..<1000 where !controller.nativeConnected { await Task.yield() }
    assert(GCVirtualController.attempts == 2 && controller.nativeConnected && controller.deviceConnectionError == nil)
    assert(published === controller.systemDevice?.controller && controller.transferredButton)
    exit(0)
}
dispatchMain()
