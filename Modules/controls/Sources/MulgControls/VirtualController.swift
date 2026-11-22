import Foundation
import CoreGraphics
import MulgContracts
import MulgControlsHooks

#if canImport(GameController)
import GameController
#endif

/// The left stick from keys (W/A/S/D-style bindings), with a walk modifier for half tilt.
public struct KeyStick: Sendable, Equatable {
    private var movement = DigitalJoystick()
    public var up: Bool { movement.isHeld(.up) }
    public var down: Bool { movement.isHeld(.down) }
    public var left: Bool { movement.isHeld(.left) }
    public var right: Bool { movement.isHeld(.right) }
    public var walking = false

    public init() {}

    public mutating func set(_ element: VirtualControllerElement, pressed: Bool) {
        let direction: DigitalJoystick.Direction
        switch element {
        case .leftStickUp, .dpadUp: direction = .up
        case .leftStickDown, .dpadDown: direction = .down
        case .leftStickLeft, .dpadLeft: direction = .left
        case .leftStickRight, .dpadRight: direction = .right
        default: return
        }
        movement.set(direction, pressed: pressed)
    }

    public var value: (x: Float, y: Float) {
        let vector = movement.vector(magnitude: walking ? 0.5 : 1)
        return (Float(vector.dx), Float(vector.dy))
    }
}

/// Keyboard and mouse as a game controller (PLAN.md §14.1).
///
/// Catalyst connects Apple's hidden GCVirtualController and drives its public input methods.
/// A writable snapshot preserves input state during startup and in host-side tests; it is
/// replaced by the system-connected device once a game window exists. All values come from
/// the user's own input (§15).
@MainActor
public final class VirtualController {
    public private(set) var bindings: [Int: VirtualControllerElement]
    private var keyStick = KeyStick()
    private var dpadState = KeyStick()
    private var lastLeftStick: CGVector?
    private var lastDpad: CGVector?
    private var definitions: [Int: ControllerBinding] = [:]
    private var physicalKeys: Set<Int> = []
    /// Resolved actions belong to their press, even if aim/menu state changes before release.
    private var heldInputs: [Int: [VirtualControllerElement]] = [:]
    private var appliedElements: Set<VirtualControllerElement> = []
    private var inputGeneration: UInt64 = 0
    private var releasingAll = false
    private var rightStick: StickCurve
    private var decayTask: Task<Void, Never>?
    private var mouseUpdatedSinceFrame = false
    private var lastFrameTime: ContinuousClock.Instant?
    #if canImport(GameController)
    private let snapshotController: GCController
    public var controller: GCController {
        #if canImport(UIKit) && targetEnvironment(macCatalyst)
        if nativeConnected, let native = systemDevice?.controller { return native }
        #endif
        return snapshotController
    }
    public private(set) var deviceConnectionError: String?
    #if canImport(UIKit) && targetEnvironment(macCatalyst)
    private var systemDevice: GCVirtualController?
    private var nativeConnectionTask: Task<Void, Never>?
    private var nativeConnected = false
    #endif
    #endif

    public init(bindings: [ControllerBinding], stickCurve: StickCurveSettings) {
        var map: [Int: VirtualControllerElement] = [:]
        for binding in bindings {
            map[binding.keyCode] = binding.element
            definitions[binding.keyCode] = binding
        }
        self.bindings = map
        rightStick = StickCurve(settings: stickCurve)
        #if canImport(GameController)
        snapshotController = GCController.withExtendedGamepad()
        mulg_controller_set_virtual(snapshotController)
        #endif
    }

    /// Uses another keymap's bindings (after switching keymaps). Held inputs are released first.
    public func rebind(_ bindings: [ControllerBinding]) {
        releaseAll()
        definitions.removeAll()
        var map: [Int: VirtualControllerElement] = [:]
        for binding in bindings {
            map[binding.keyCode] = binding.element
            definitions[binding.keyCode] = binding
        }
        self.bindings = map
    }

    /// Call once the game has a window. A snapshot alone is not a connected input device,
    /// and games may filter it out even when our compatibility list includes it.
    public func connectNativeDevice() {
        #if canImport(UIKit) && targetEnvironment(macCatalyst)
        guard systemDevice == nil, nativeConnectionTask == nil else { return }
        let configuration = GCVirtualController.Configuration()
        configuration.isHidden = true // no touch overlay or blocked window chrome
        configuration.elements = [GCInputLeftThumbstick, GCInputRightThumbstick,
            GCInputDirectionPad, GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY,
            GCInputLeftShoulder, GCInputRightShoulder, GCInputLeftTrigger, GCInputRightTrigger,
            GCInputButtonMenu, GCInputButtonOptions]
        let device = GCVirtualController(configuration: configuration)
        systemDevice = device
        nativeConnectionTask = Task { @MainActor [weak self] in
            do {
                try await device.connect()
                guard let self, !Task.isCancelled, self.systemDevice === device else {
                    device.disconnect(); return
                }
                guard let native = device.controller, native.extendedGamepad != nil else {
                    device.disconnect()
                    self.nativeConnectionTask = nil
                    self.systemDevice = nil
                    self.deviceConnectionError = "The virtual controller connected without an extended gamepad."
                    return
                }
                self.nativeConnected = true
                self.deviceConnectionError = nil
                // Bring held input across before replacing the startup snapshot.
                self.applyLeftStick(force: true); self.applyRightStick()
                for element in VirtualControllerElement.allCases {
                    self.setButton(element, value: self.appliedElements.contains(element) ? 1 : 0, updateDpad: false)
                }
                self.applyDpad(force: true)
                mulg_controller_set_virtual(native)
                self.nativeConnectionTask = nil
            } catch {
                guard let self, !Task.isCancelled, self.systemDevice === device else { device.disconnect(); return }
                self.deviceConnectionError = String(describing: error)
                self.nativeConnectionTask = nil
                self.systemDevice = nil
            }
        }
        #endif
    }

    /// Both identities belong to us during connection; never map our own output to touches.
    public func owns(_ candidate: GCController) -> Bool {
        if candidate === snapshotController { return true }
        #if canImport(UIKit) && targetEnvironment(macCatalyst)
        return candidate === systemDevice?.controller
        #else
        return false
        #endif
    }

    /// Removes the controller from the game's list.
    public func disconnect() {
        releaseAll()
        #if canImport(UIKit) && targetEnvironment(macCatalyst)
        nativeConnectionTask?.cancel(); nativeConnectionTask = nil
        nativeConnected = false
        systemDevice?.disconnect(); systemDevice = nil
        #endif
        mulg_controller_set_virtual(nil)
    }

    public func element(forKeyCode code: Int) -> VirtualControllerElement? {
        bindings[code]
    }

    // MARK: Buttons and the left stick

    /// Returns true when the key is bound.
    @discardableResult
    public func key(code: Int, pressed: Bool, inMenu: Bool = false) -> Bool {
        guard !releasingAll else { return false }
        guard let binding = definitions[code] else { return false }
        if pressed {
            guard physicalKeys.insert(code).inserted else { return true }
            if binding.toggle == true, heldInputs[code] != nil {
                heldInputs.removeValue(forKey: code)
            } else {
                let alternate = binding.alternateWhile.map(isActive) == true
                    ? binding.alternateElement : nil
                let element = (inMenu ? binding.menuElement : nil) ?? alternate ?? binding.element
                if let releasing = binding.releaseToggles {
                    let latched = heldInputs.keys.filter { key in
                        definitions[key]?.toggle == true && heldInputs[key]?.contains(where: releasing.contains) == true
                    }
                    for key in latched { heldInputs.removeValue(forKey: key) }
                }
                heldInputs[code] = (binding.chord ?? []) + [element]
            }
        } else {
            physicalKeys.remove(code)
            if binding.toggle != true { heldInputs.removeValue(forKey: code) }
        }
        applyHeldInputs()
        return true
    }

    public func usesAlternateAction(forKeyCode code: Int) -> Bool {
        guard let binding = definitions[code], binding.alternateElement != nil,
              let condition = binding.alternateWhile else { return false }
        return isActive(condition)
    }

    public func isActive(_ element: VirtualControllerElement) -> Bool {
        heldInputs.values.contains { $0.contains(element) }
    }

    private func applyHeldInputs() {
        inputGeneration &+= 1
        let generation = inputGeneration
        let held = Set(heldInputs.values.flatMap { $0 })
        for element in [VirtualControllerElement.leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight] {
            keyStick.set(element, pressed: held.contains(element))
        }
        applyLeftStick()
        guard generation == inputGeneration else { return }
        // Resolve ALL digital directions before publishing any D-pad transition. This
        // avoids temporary diagonals when several bindings/chords change together.
        for element in [VirtualControllerElement.dpadUp, .dpadDown, .dpadLeft, .dpadRight] {
            dpadState.set(element, pressed: held.contains(element))
        }
        // Modifiers precede the shortcut button on press, and outlive it on release.
        // Unchanged aliases do not emit redundant controller callbacks.
        let order: [VirtualControllerElement] = [.leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger,
            .leftThumbstickButton, .rightThumbstickButton, .buttonA, .buttonB, .buttonX, .buttonY,
            .dpadUp, .dpadDown, .dpadLeft, .dpadRight, .buttonMenu, .buttonOptions]
        for element in order.reversed() where appliedElements.contains(element) && !held.contains(element) {
            setButton(element, value: 0, updateDpad: false)
            guard generation == inputGeneration else { return }
        }
        for element in order where held.contains(element) && !appliedElements.contains(element) {
            setButton(element, value: 1, updateDpad: false)
            guard generation == inputGeneration else { return }
        }
        applyDpad()
        guard generation == inputGeneration else { return }
        appliedElements = held
    }

    public func setWalking(_ walking: Bool) {
        keyStick.walking = walking
        applyLeftStick()
    }

    public func set(_ element: VirtualControllerElement, pressed: Bool) {
        switch element {
        case .leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight:
            keyStick.set(element, pressed: pressed)
            applyLeftStick()
        default:
            setButton(element, value: pressed ? 1 : 0)
        }
    }

    private func applyLeftStick(force: Bool = false) {
        #if canImport(GameController)
        let value = keyStick.value
        let vector = CGVector(dx: CGFloat(value.x), dy: CGFloat(value.y))
        guard force || vector != lastLeftStick else { return }
        lastLeftStick = vector
        let generation = inputGeneration
        snapshotController.extendedGamepad?.leftThumbstick.setValueForXAxis(value.x, yAxis: value.y)
        guard generation == inputGeneration else { return }
        #if canImport(UIKit) && targetEnvironment(macCatalyst)
        if nativeConnected { systemDevice?.setPosition(CGPoint(x: CGFloat(value.x), y: CGFloat(value.y)), forDirectionPadElement: GCInputLeftThumbstick) }
        #endif
        #endif
    }

    private func applyDpad(force: Bool = false) {
        #if canImport(GameController)
        let position = dpadState.value
        let vector = CGVector(dx: CGFloat(position.x), dy: CGFloat(position.y))
        guard force || vector != lastDpad else { return }
        lastDpad = vector
        let generation = inputGeneration
        snapshotController.extendedGamepad?.dpad.setValueForXAxis(position.x, yAxis: position.y)
        guard generation == inputGeneration else { return }
        #if canImport(UIKit) && targetEnvironment(macCatalyst)
        if nativeConnected {
            systemDevice?.setPosition(CGPoint(x: CGFloat(position.x), y: CGFloat(position.y)), forDirectionPadElement: GCInputDirectionPad)
        }
        #endif
        #endif
    }

    private func setButton(_ element: VirtualControllerElement, value: Float, updateDpad: Bool = true) {
        #if canImport(GameController)
        guard let pad = snapshotController.extendedGamepad else { return }
        let generation = inputGeneration
        switch element {
        case .buttonA: pad.buttonA.setValue(value)
        case .buttonB: pad.buttonB.setValue(value)
        case .buttonX: pad.buttonX.setValue(value)
        case .buttonY: pad.buttonY.setValue(value)
        case .leftShoulder: pad.leftShoulder.setValue(value)
        case .rightShoulder: pad.rightShoulder.setValue(value)
        case .leftTrigger: pad.leftTrigger.setValue(value)
        case .rightTrigger: pad.rightTrigger.setValue(value)
        case .dpadUp, .dpadDown, .dpadLeft, .dpadRight:
            // Direction-pad child buttons are derived from axes on a software controller;
            // setValue on the children does not change the values the game reads.
            if updateDpad { dpadState.set(element, pressed: value > 0) }
            applyDpad()
        case .leftThumbstickButton: pad.leftThumbstickButton?.setValue(value)
        case .rightThumbstickButton: pad.rightThumbstickButton?.setValue(value)
        case .buttonMenu: pad.buttonMenu.setValue(value)
        case .buttonOptions: pad.buttonOptions?.setValue(value)
        case .leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight: break
        }
        // Snapshot callbacks can reset/rebind controls before the connected-device
        // write. That older value must not outlive the reset.
        guard generation == inputGeneration else { return }
        #if canImport(UIKit) && targetEnvironment(macCatalyst)
        if nativeConnected, let name = nativeButtonName(element) {
            systemDevice?.setValue(CGFloat(value), forButtonElement: name)
        }
        #endif
        #endif
    }

    #if canImport(GameController)
    private func nativeButtonName(_ element: VirtualControllerElement) -> String? {
        switch element {
        case .buttonA: GCInputButtonA
        case .buttonB: GCInputButtonB
        case .buttonX: GCInputButtonX
        case .buttonY: GCInputButtonY
        case .leftShoulder: GCInputLeftShoulder
        case .rightShoulder: GCInputRightShoulder
        case .leftTrigger: GCInputLeftTrigger
        case .rightTrigger: GCInputRightTrigger
        case .buttonMenu: GCInputButtonMenu
        case .buttonOptions: GCInputButtonOptions
        case .leftThumbstickButton: GCInputLeftThumbstickButton
        case .rightThumbstickButton: GCInputRightThumbstickButton
        default: nil
        }
    }
    #endif

    // MARK: The right stick from the mouse

    public func mouseMoved(dx: Double, dy: Double) {
        mouseUpdatedSinceFrame = true
        rightStick.push(dx: dx, dy: dy)
        applyRightStick()
        startDecay()
    }

    private func applyRightStick() {
        #if canImport(GameController)
        let generation = inputGeneration
        snapshotController.extendedGamepad?.rightThumbstick.setValueForXAxis(Float(rightStick.x), yAxis: Float(rightStick.y))
        guard generation == inputGeneration else { return }
        #if canImport(UIKit) && targetEnvironment(macCatalyst)
        if nativeConnected { systemDevice?.setPosition(CGPoint(x: rightStick.x, y: rightStick.y), forDirectionPadElement: GCInputRightThumbstick) }
        #endif
        #endif
    }

    /// Let at least one game frame sample the new mouse input before centering it.
    /// An 8 ms timer could erase an entire flick before a 30/60 Hz game read the stick.
    public func frameStarts() {
        lastFrameTime = .now
        if mouseUpdatedSinceFrame {
            mouseUpdatedSinceFrame = false
        } else {
            rightStick.decay()
            applyRightStick()
        }
    }

    /// Fallback for engines with no display-link callback, bounded when rendering stops.
    private func startDecay() {
        guard decayTask == nil else { return }
        decayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(8))
                guard let self else { return }
                guard !Task.isCancelled else { return }
                if self.lastFrameTime.map({ $0.duration(to: .now) > .milliseconds(100) }) ?? true {
                    self.rightStick.decay()
                    self.applyRightStick()
                }
                if self.rightStick.isCentred {
                    self.decayTask = nil
                    return
                }
            }
        }
    }

    public func updateStickCurve(_ settings: StickCurveSettings) {
        guard rightStick.settings != settings else { return }
        rightStick = StickCurve(settings: settings)
        applyRightStick()
    }

    /// Releases every button and centres both sticks.
    public func releaseAll() {
        guard !releasingAll else { return }
        releasingAll = true
        defer { releasingAll = false }
        // Native input callbacks may synchronously open a field, switch modes or
        // rebuild the map. An older chord publication must stop after that reset.
        inputGeneration &+= 1
        decayTask?.cancel()
        decayTask = nil
        mouseUpdatedSinceFrame = false
        lastFrameTime = nil
        physicalKeys.removeAll()
        heldInputs.removeAll()
        appliedElements.removeAll()
        keyStick = KeyStick()
        dpadState = KeyStick()
        applyLeftStick()
        applyDpad()
        for element in VirtualControllerElement.allCases {
            set(element, pressed: false)
        }
        rightStick = StickCurve(settings: rightStick.settings)
        applyRightStick()
    }
}
