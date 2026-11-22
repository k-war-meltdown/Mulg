import CoreGraphics
import Foundation
import MulgContracts
import Synchronization

#if canImport(GameController)
import GameController

/// A real controller mapped to touches for games without controller support (upstream
/// TouchscreenControllerEventAdapter). Elements are dispatched by Apple's alias names
/// ("Button A", "Left Thumbstick", …), which is how keymaps store them.
@MainActor
public final class ControllerInput {
    private let dispatcher: ActionDispatcher
    private weak var virtualController: GCController?
    private let isVirtualController: ((GCController) -> Bool)?
    private var observers: [NSObjectProtocol] = []
    @MainActor private final class Device {
        weak var controller: GCController?
        var connected = true
        var dpadX: Float = 0
        var dpadY: Float = 0
        var buttons: Set<String> = []
        var sticks: [String: CGVector] = [:]
        var rawSticks: [String: CGVector] = [:]
        nonisolated let lifecycle = Mutex((generation: UInt64(0), enabled: true))
        init(_ controller: GCController) { self.controller = controller }
    }
    private var devices: [ObjectIdentifier: Device] = [:]
    private var stickOwners: [String: ObjectIdentifier] = [:]
    private var motionOwner: ObjectIdentifier?
    private var cameraSticks: [String: CGVector] = [:]
    /// Buttons held down right now, so a controller that disconnects mid-press lets go.
    private var heldButtons: Set<String> = []
    /// Movement sticks away from centre, so a disconnect mid-tilt centres them.
    private var tiltedSticks: Set<String> = []
    private var pollTask: Task<Void, Never>?
    /// The last camera step, and the last one a frame start made (`frameStarted`).
    private var lastCameraStep: ContinuousClock.Instant?
    private var lastFrameStep: ContinuousClock.Instant?
    private var active = true
    private var textInputActive = false
    private var releasingInputs = false
    var onButton: ((String, Bool) -> Bool)?
    var acceptsTouchMapping: (() -> Bool)?
    var acceptsCameraMapping: (() -> Bool)?
    private var sticks: ControllerStickSettings
    /// A real controller's motion sensor, for gyro from a controller (§14.3).
    public var onMotion: ((Double, Double, Double) -> Void)?
    /// While the keymap editor is open, controller presses bind the selected element instead.
    public var editorSink: ((String) -> Void)? {
        didSet {
            guard (oldValue != nil) != (editorSink != nil) else { return }
            keymapRebuilt()
        }
    }

    public init(dispatcher: ActionDispatcher, virtualController: GCController?,
                sticks: ControllerStickSettings = ControllerStickSettings(),
                isVirtualController: ((GCController) -> Bool)? = nil) {
        self.sticks = sticks
        self.dispatcher = dispatcher
        self.virtualController = virtualController
        self.isVirtualController = isVirtualController
        GCController.shouldMonitorBackgroundEvents = true
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] notification in
            // Delivered on the main queue; the object is only read there.
            nonisolated(unsafe) let object = notification.object
            MainActor.assumeIsolated {
                guard let controller = object as? GCController else { return }
                self?.attach(controller)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] notification in
            nonisolated(unsafe) let object = notification.object
            MainActor.assumeIsolated {
                guard let self, let controller = object as? GCController,
                      controller !== self.virtualController else { return }
                self.disconnect(controller)
            }
        })
        GCController.controllers().forEach(attach)
    }

    func attach(_ controller: GCController) {
        // Never feed our own virtual controller back into the keymap.
        guard controller !== virtualController, isVirtualController?(controller) != true, let pad = controller.extendedGamepad else { return }
        devices = devices.filter { $0.value.controller != nil }
        let identity = ObjectIdentifier(controller)
        let device = devices[identity] ?? Device(controller)
        devices[identity] = device
        device.connected = true
        device.lifecycle.withLock { $0.generation &+= 1; $0.enabled = active && !textInputActive }
        // Games with native controller handling keep their own callback.
        if pad.valueChangedHandler == nil {
            pad.valueChangedHandler = { [weak self, device] profile, element in
                guard let generation = device.lifecycle.withLock({ $0.enabled ? $0.generation : nil }),
                      let sample = Sample.capture(element) else { return }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.changed(sample, controller: identity, generation: generation) }
                } else {
                    DispatchQueue.main.async { [weak self] in self?.changed(sample, controller: identity, generation: generation) }
                }
            }
        }
        if let motion = controller.motion, motion.valueChangedHandler == nil {
            if motion.sensorsRequireManualActivation {
                motion.sensorsActive = true
            }
            motion.valueChangedHandler = { [weak self, device] motion in
                guard let generation = device.lifecycle.withLock({ $0.enabled ? $0.generation : nil }) else { return }
                let rate = motion.rotationRate
                let (x, y, z) = (rate.x, rate.y, rate.z)
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        guard let self, self.editorSink == nil, self.accepts(identity, generation: generation) else { return }
                        self.motionOwner = identity
                        self.onMotion?(x, y, z)
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.editorSink == nil, self.accepts(identity, generation: generation) else { return }
                            self.motionOwner = identity
                            self.onMotion?(x, y, z)
                        }
                    }
                }
            }
        }
    }

    enum Sample: Sendable {
        case button(String, Bool)
        case stick(String, Float, Float)
        case dpad(Float, Float, [Sample?])
        indirect case aliased(Sample, [String])

        private static let standardNames: Set<String> = ["Button A", "Button B", "Button X", "Button Y", "Button Menu", "Button Options",
                "Left Shoulder", "Right Shoulder", "Left Trigger", "Right Trigger", "Left Thumbstick", "Right Thumbstick",
                "Left Thumbstick Button", "Right Thumbstick Button", "Direction Pad", "Direction Pad Up",
                "Direction Pad Down", "Direction Pad Left", "Direction Pad Right"]

        static func capture(_ element: GCControllerElement) -> Sample? {
            let aliases = element.aliases
            let names = aliases.sorted { lhs, rhs in
                standardNames.contains(lhs) == standardNames.contains(rhs) ? lhs < rhs : standardNames.contains(lhs)
            }
            guard let name = names.first else { return nil }
            func withAliases(_ sample: Sample) -> Sample { names.count > 1 ? .aliased(sample, names) : sample }
            if let button = element as? GCControllerButtonInput { return withAliases(.button(name, button.isPressed)) }
            guard let pad = element as? GCControllerDirectionPad else { return nil }
            if name == "Direction Pad" {
                return .dpad(pad.xAxis.value, pad.yAxis.value, [pad.right, pad.left, pad.up, pad.down].map(capture))
            }
            return withAliases(.stick(name, pad.xAxis.value, pad.yAxis.value))
        }
    }

    func token(for controller: GCController) -> UInt64? {
        devices[ObjectIdentifier(controller)]?.lifecycle.withLock { $0.enabled ? $0.generation : nil }
    }

    private func accepts(_ identity: ObjectIdentifier, generation: UInt64) -> Bool {
        guard active, let device = devices[identity], device.connected else { return false }
        return device.lifecycle.withLock { $0.enabled && $0.generation == generation }
    }

    func changed(_ sample: Sample, controller identity: ObjectIdentifier, generation: UInt64) {
        guard accepts(identity, generation: generation), let device = devices[identity] else { return }
        switch sample {
        case .aliased(let value, let names):
            // Resolve against the current map on the main actor. Vendor-specific aliases
            // remain usable; a Set's iteration order must not select a different binding.
            let name = names.first { dispatcher.hasMapping(for: $0) || dispatcher.layer(heldBy: $0) != nil } ?? names[0]
            switch value {
            case .button(_, let pressed):
                let owned = names.first { device.buttons.contains($0) } ?? name
                changed(.button(owned, pressed), controller: identity, generation: generation)
            case .stick(_, let x, let y):
                let owned = names.first { device.rawSticks[$0] != nil } ?? name
                changed(.stick(owned, x, y), controller: identity, generation: generation)
            default: changed(value, controller: identity, generation: generation)
            }
        case .button(let name, let pressed):
            if let editorSink {
                if pressed { editorSink(name) }
                return
            }
            if pressed { device.buttons.insert(name) } else { device.buttons.remove(name) }
            let held = devices.values.contains { $0.buttons.contains(name) }
            let wasHeld = heldButtons.contains(name)
            if held { heldButtons.insert(name) } else { heldButtons.remove(name) }
            if held != wasHeld { dispatchButton(name, pressed: held) }
        case .dpad(let x, let y, let buttons):
            let changes = [(x > 0) != (device.dpadX > 0), (x < 0) != (device.dpadX < 0),
                           (y > 0) != (device.dpadY > 0), (y < 0) != (device.dpadY < 0)]
            dispatcher.withInputTransaction {
                for (button, didChange) in zip(buttons, changes) where didChange {
                    if let button { changed(button, controller: identity, generation: generation) }
                }
            }
            // A button callback can synchronously reset/disconnect this device.
            // Do not restore its old axes after that reset has cleared them.
            guard accepts(identity, generation: generation) else { return }
            device.dpadX = x
            device.dpadY = y
        case .stick(let name, let x, let y):
            if let editorSink {
                if abs(x) + abs(y) > 0.5 { editorSink(name) }
                return
            }
            let raw = CGVector(dx: CGFloat(x), dy: CGFloat(y))
            if raw == .zero { device.rawSticks.removeValue(forKey: name) } else { device.rawSticks[name] = raw }
            let shaped = StickResponse.shape(x: Double(x), y: Double(y), settings: sticks)
            let value = CGVector(dx: CGFloat(shaped.x), dy: CGFloat(shaped.y))
            if value == .zero { device.sticks.removeValue(forKey: name) } else { device.sticks[name] = value }
            if value != .zero { stickOwners[name] = identity }
            reapplyStick(name)
        }
    }

    private func dispatchButton(_ name: String, pressed: Bool) {
        if let onButton { _ = onButton(name, pressed) }
        else { dispatcher.dispatch(key: name, pressed: pressed, source: .controller) }
    }

    private func directionPad(name: String, x: Float, y: Float) {
        guard acceptsTouchMapping?() != false else { return }
        let stick = (x: x, y: y)
        switch dispatcher.motionPriority(for: name) {
        case nil:
            return
        case .normal?:
            if stick.x == 0 && stick.y == 0 {
                tiltedSticks.remove(name)
            } else {
                tiltedSticks.insert(name)
            }
            dispatcher.dispatch(key: name, x: CGFloat(stick.x), y: CGFloat(stick.y))
        case .camera?, .draggable?:
            guard dispatcher.motionPriority(for: name) == .draggable || acceptsCameraMapping?() != false else {
                cameraSticks.removeValue(forKey: name); return
            }
            // Camera/skill-drag sticks specify speed, so motion continues while held.
            cameraSticks[name] = CGVector(dx: CGFloat(stick.x) * 6, dy: CGFloat(stick.y) * 6)
            startPolling()
        }
    }

    private func reapplyStick(_ name: String) {
        if let owner = stickOwners[name], let value = devices[owner]?.sticks[name] {
            directionPad(name: name, x: Float(value.dx), y: Float(value.dy))
        } else if let replacement = devices.first(where: { $0.value.sticks[name] != nil }),
                  let value = replacement.value.sticks[name] {
            stickOwners[name] = replacement.key
            directionPad(name: name, x: Float(value.dx), y: Float(value.dy))
        } else {
            stickOwners.removeValue(forKey: name)
            directionPad(name: name, x: 0, y: 0)
        }
    }

    func disconnect(_ controller: GCController) {
        let identity = ObjectIdentifier(controller)
        guard let device = devices[identity] else { return }
        device.connected = false
        device.lifecycle.withLock { $0.generation &+= 1; $0.enabled = false }
        let buttons = device.buttons, sticks = Array(device.sticks.keys)
        device.buttons.removeAll(); device.sticks.removeAll(); device.rawSticks.removeAll()
        device.dpadX = 0; device.dpadY = 0
        for name in buttons where !devices.values.contains(where: { $0.buttons.contains(name) }) {
            heldButtons.remove(name)
            dispatchButton(name, pressed: false)
        }
        for name in sticks where stickOwners[name] == identity { reapplyStick(name) }
        if motionOwner == identity { motionOwner = nil; onMotion?(0, 0, 0) }
    }

    /// A disconnected controller sends no releases: lift its buttons, centre its movement sticks
    /// and stop its camera sticks.
    private func releaseEverything() {
        guard !releasingInputs else { return }
        releasingInputs = true
        defer { releasingInputs = false }
        for device in devices.values {
            device.lifecycle.withLock { $0.generation &+= 1; $0.enabled = false }
            device.buttons.removeAll(); device.sticks.removeAll(); device.rawSticks.removeAll()
            device.dpadX = 0; device.dpadY = 0
        }
        for name in heldButtons {
            dispatchButton(name, pressed: false)
        }
        heldButtons.removeAll()
        // Centring lifts the joystick touch, or the character keeps walking.
        for name in tiltedSticks {
            dispatcher.dispatch(key: name, x: 0, y: 0)
        }
        tiltedSticks.removeAll()
        cameraSticks.removeAll()
        stickOwners.removeAll()
        motionOwner = nil
        pollTask?.cancel()
        pollTask = nil
        onMotion?(0, 0, 0)
    }

    public func focusLost() {
        guard active else { return }
        active = false
        releaseEverything()
    }

    public func focusGained() {
        guard !active else { return }
        active = true
        enableDevices()
    }

    public func setTextInputActive(_ editing: Bool) {
        guard editing != textInputActive else { return }
        textInputActive = editing
        keymapRebuilt()
    }

    /// Releases the old mapping and rejects samples queued before an editor/mapping change.
    public func keymapRebuilt() {
        releaseEverything()
        enableDevices()
    }

    /// Reapply a held analog stick when its layer/mode changes, without waiting for
    /// another physical change callback. Cancel old camera polling before replay.
    func mappingContextChanged() {
        guard active, !textInputActive, !releasingInputs, editorSink == nil else { return }
        let names = Set(stickOwners.keys).union(devices.values.flatMap { $0.sticks.keys })
        cameraSticks.removeAll()
        tiltedSticks.removeAll()
        pollTask?.cancel()
        pollTask = nil
        for name in names.sorted() { reapplyStick(name) }
    }

    public func updateStickSettings(_ settings: ControllerStickSettings) {
        guard sticks != settings else { return }
        sticks = settings
        let names = Set(devices.values.flatMap { $0.rawSticks.keys }).union(stickOwners.keys)
        for device in devices.values {
            device.sticks.removeAll(keepingCapacity: true)
            for (name, raw) in device.rawSticks {
                let shaped = StickResponse.shape(x: Double(raw.dx), y: Double(raw.dy), settings: settings)
                let value = CGVector(dx: CGFloat(shaped.x), dy: CGFloat(shaped.y))
                if value != .zero { device.sticks[name] = value }
            }
        }
        // Samples are raw snapshots, so queued input also uses the new curve at dispatch.
        // Buttons/motion and the focus/editor epochs need no changes.
        for name in names { reapplyStick(name) }
    }

    private func enableDevices() {
        for device in devices.values where device.connected {
            device.lifecycle.withLock { $0.generation &+= 1; $0.enabled = active && !textInputActive }
        }
    }

    /// Stick speeds are per 60 Hz step; each step is scaled by the time since the last one, so
    /// turning speed is the same at any frame rate.
    static func stepScale(elapsed: Duration) -> CGFloat {
        CGFloat(min(elapsed / .microseconds(16_667), 3))
    }

    /// Main thread, at each game frame start, before touches are flushed to the game: the camera
    /// moves once per frame, in step with what the game draws, instead of on a timer that drifts
    /// against the frames.
    public func frameStarted() {
        guard pollTask != nil else { return }
        let now = ContinuousClock.now
        lastFrameStep = now
        stepCamera(at: now)
    }

    /// The camera sticks moving now that the current mapping lets through.
    private var movingCameraSticks: [(name: String, velocity: CGVector)] {
        cameraSticks.filter { name, velocity in
            guard abs(velocity.dx) + abs(velocity.dy) > 0.1 else { return false }
            let priority = dispatcher.motionPriority(for: name)
            return priority == .draggable || priority == .camera && acceptsCameraMapping?() != false
        }.map { (name: $0.key, velocity: $0.value) }
    }

    /// One camera step; false when no stick moves.
    @discardableResult
    private func stepCamera(at now: ContinuousClock.Instant) -> Bool {
        guard active, !textInputActive, editorSink == nil, acceptsTouchMapping?() != false else { return false }
        let scale = Self.stepScale(elapsed: now - (lastCameraStep ?? now - .milliseconds(8)))
        lastCameraStep = now
        let moving = movingCameraSticks
        for (name, velocity) in moving {
            dispatcher.dispatch(key: name, x: velocity.dx * scale, y: velocity.dy * scale)
        }
        return !moving.isEmpty
    }

    /// Keeps the camera moving while a stick is held. Frame starts do the steps; this loop steps
    /// only for engines that draw without them, and ends once no stick moves.
    private func startPolling() {
        guard pollTask == nil else { return }
        lastCameraStep = ContinuousClock.now - .milliseconds(8)
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.active, !self.textInputActive, self.editorSink == nil else { return }
                guard self.acceptsTouchMapping?() != false else {
                    self.pollTask = nil
                    return
                }
                let now = ContinuousClock.now
                let framesDrive = self.lastFrameStep.map { now - $0 < .milliseconds(50) } ?? false
                let moving = framesDrive ? !self.movingCameraSticks.isEmpty : self.stepCamera(at: now)
                if !moving {
                    self.pollTask = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }
}
#endif
