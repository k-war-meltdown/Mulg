import CoreGraphics
import Foundation
import MulgContracts

/// When one key drives several mappings, the lowest priority number wins (upstream order).
public enum DispatchPriority: Int, Sendable, CaseIterable, Comparable {
    case draggable = 0
    case normal = 1
    case camera = 2
    public static func < (lhs: DispatchPriority, rhs: DispatchPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Named-input dispatcher. A press owns its handler snapshot until the final source release;
/// repeated downs and orphan ups cannot move that ownership. Movement alone can transfer
/// to another layer, in one transaction, without triggering unrelated button actions.
/// Mouse-look additionally owns a persistent motion path, parallel to held gameplay drags.
@MainActor
public final class ActionDispatcher {
    public typealias ButtonHandler = @MainActor (Bool) -> Void
    public typealias DirectionHandler = @MainActor (CGFloat, CGFloat) -> Void
    public typealias Layer = Int

    private struct ButtonRegistration {
        let handler: ButtonHandler
        let transfersMovement: Bool
        let renewsCamera: Bool
    }
    private struct PressOwnership {
        let layer: Layer
        let registrations: [ButtonRegistration]
        /// Retained when a held movement key is suppressed by a non-movement layer.
        let transfersMovement: Bool
    }
    private struct MotionRegistration {
        let id: UInt64
        let key: String
        let handler: DirectionHandler
    }
    private var buttonHandlers: [Layer: [String: [ButtonRegistration]]] = [:]
    private var directionHandlers: [Layer: [DispatchPriority: [MotionRegistration]]] = [:]
    /// Mouse-look belongs to the map, independently of held keyboard/button layers and drags.
    private var mouseView: MotionRegistration?
    private(set) var mouseViewLayer: Layer?
    private var layerActions: [Layer: [any MulgAction]] = [:]
    private var pressedIn: [String: PressOwnership] = [:]
    private var heldInputs = HeldInputState()
    private var nextMotionRegistration: UInt64 = 0
    private var buildingLayer: Layer?
    public private(set) var layerKeys: [String: Layer] = [:]
    public private(set) var activeLayer: Layer = 0
    public private(set) var repeatedPresses = 0
    public private(set) var orphanReleases = 0
    public private(set) var movementTransfers = 0
    public var heldInputCount: Int { heldInputs.count }
    public var suppressedMovementCount: Int { pressedIn.values.filter { $0.registrations.isEmpty }.count }
    var hasActiveGameplayTouches: Bool {
        layerActions.values.contains { $0.contains { $0.hasActiveGameplayTouch } }
    }

    public init() {}
    public var actions: [any MulgAction] { layerActions.keys.sorted().flatMap { layerActions[$0] ?? [] } }

    public func resize(to metrics: ScreenMetrics) {
        guard metrics.width > 0, metrics.height > 0 else { return }
        for action in actions { action.resize(to: metrics) }
    }
    public func rebindSurface(to metrics: ScreenMetrics) { for action in actions { action.rebindSurface(to: metrics) } }
    public func setLiveResizing(_ resizing: Bool) { for action in actions { action.setLiveResizing(resizing) } }
    public func commitViewport(to metrics: ScreenMetrics) { for action in actions { action.commitViewport(to: metrics) } }

    // MARK: Building
    public func add(_ action: any MulgAction) { layerActions[buildingLayer ?? 0, default: []].append(action) }
    public func beginLayer(_ layer: Layer, holdKey: String) {
        precondition(layer > 0, "layer 0 is the base keymap")
        buildingLayer = layer
        layerKeys[holdKey] = layer
    }
    public func endLayer() { buildingLayer = nil }

    public func clear() {
        invalidateAll()
        layerActions.removeAll()
        buttonHandlers.removeAll(keepingCapacity: true)
        directionHandlers.removeAll(keepingCapacity: true)
        mouseView = nil
        mouseViewLayer = nil
        layerKeys.removeAll()
        buildingLayer = nil
        activeLayer = 0
        // Never reset registration identity: a stale release cannot remove a new drag.
    }

    public func register(key: String, transfersMovement: Bool = false, renewsCamera: Bool = false, handler: @escaping ButtonHandler) {
        buttonHandlers[registrationLayer, default: [:]][key, default: []]
            .append(ButtonRegistration(handler: handler, transfersMovement: transfersMovement, renewsCamera: renewsCamera))
    }

    /// Static handlers replace at equal priority; held drags form an ownership stack.
    /// The most recently grabbed drag gets motion until it releases, revealing the prior one.
    @discardableResult
    public func register(key: String, priority: DispatchPriority = .normal, handler: @escaping DirectionHandler) -> UInt64 {
        nextMotionRegistration &+= 1
        let entry = MotionRegistration(id: nextMotionRegistration, key: key, handler: handler)
        let layer = registrationLayer
        var list = directionHandlers[layer]?[priority] ?? []
        if priority != .draggable { list.removeAll { $0.key == key } }
        list.append(entry)
        directionHandlers[layer, default: [:]][priority] = list
        if key == KeymapNames.mouseMove && priority != .draggable { refreshMouseView() }
        return entry.id
    }

    private func refreshMouseView() {
        // Prefer the base view, then the first mapped layer. A mouse-driven analog stick remains
        // usable for maps without a Camera area. Resolve only while building, never per frame.
        let layers = directionHandlers.keys.sorted()
        for layer in layers {
            for priority in [DispatchPriority.camera, .normal] {
                if let entry = directionHandlers[layer]?[priority]?.last(where: { $0.key == KeymapNames.mouseMove }) {
                    mouseView = entry
                    mouseViewLayer = layer
                    return
                }
            }
        }
        mouseView = nil
        mouseViewLayer = nil
    }

    func ownsMouseView(_ registration: UInt64) -> Bool { mouseView?.id == registration }

    /// While in camera mode, view motion and the held gameplay drag receive independent
    /// deliveries. Casting/aiming never steals the camera registration or changes cursor state.
    @discardableResult
    func dispatchMouseView(x: CGFloat, y: CGFloat) -> Bool {
        guard x.isFinite, y.isFinite else { return false }
        let view = mouseView
        let gameplay = activeLayer == 0 ? gameplayMouseBinding(in: 0)
            : gameplayMouseBinding(in: activeLayer) ?? gameplayMouseBinding(in: 0)
        view?.handler(x, y)
        if let gameplay, gameplay.id != view?.id { gameplay.handler(x, y) }
        return view != nil || gameplay != nil
    }

    private func gameplayMouseBinding(in layer: Layer) -> MotionRegistration? {
        directionHandlers[layer]?[.draggable]?.last(where: { $0.key == KeymapNames.mouseMove })
            ?? directionHandlers[layer]?[.normal]?.last(where: { $0.key == KeymapNames.mouseMove })
    }

    /// Releases only this dynamic registration, even if another drag uses the same mouse.
    public func unregister(registration: UInt64) {
        for layer in Array(directionHandlers.keys) {
            directionHandlers[layer]?[.draggable]?.removeAll { $0.id == registration }
        }
    }

    /// Compatibility for clients without a token. New held actions use owned registration.
    public func unregister(key: String) {
        for layer in Array(directionHandlers.keys) {
            directionHandlers[layer]?[.draggable]?.removeAll { $0.key == key }
        }
    }

    private var registrationLayer: Layer { buildingLayer ?? activeLayer }
    public func layer(heldBy key: String) -> Layer? { layerKeys[key] }

    /// One device packet may change several directions. Publish each affected joystick's
    /// final vector once; nested layer transitions use the same per-contact batching depth.
    public func withInputTransaction(_ body: () -> Void) {
        let transaction = actions
        for action in transaction { action.beginInputTransaction() }
        defer {
            // All old neutral contacts end before any new joystick origin begins.
            for action in transaction { action.flushInputReleases() }
            for action in transaction.reversed() { action.endInputTransaction() }
        }
        body()
    }

    // MARK: Context transition
    public func setActiveLayer(_ layer: Layer) {
        guard layer != activeLayer else { return }
        let transferring = pressedIn.keys.filter { key in
            guard let owner = pressedIn[key], owner.transfersMovement else { return false }
            return owner.layer != buttonLayer(for: key, in: layer) || owner.registrations.isEmpty
        }.sorted()
        let transaction = actions
        for action in transaction { action.beginInputTransaction() }
        defer {
            // All old neutral contacts end before any new joystick origin begins.
            for action in transaction { action.flushInputReleases() }
            for action in transaction.reversed() { action.endInputTransaction() }
        }

        for action in transaction where !action.isButtonLike {
            if let registration = action.mouseViewRegistration, ownsMouseView(registration) { continue }
            action.invalidate()
        }
        // Resolve every old direction before publishing any new joystick vector.
        for key in transferring {
            for registration in pressedIn[key]?.registrations ?? [] { registration.handler(false) }
        }
        activeLayer = layer
        for key in transferring {
            let target = buttonLayer(for: key, in: layer)
            let registered = buttonHandlers[target]?[key] ?? []
            let movement = !registered.isEmpty && registered.allSatisfy(\.transfersMovement) ? registered : []
            // W becoming a skill in another context must not cast it merely by entering.
            pressedIn[key] = PressOwnership(layer: target, registrations: movement, transfersMovement: true)
            for registration in movement { registration.handler(true) }
            movementTransfers += 1
        }
    }

    // MARK: Press edges
    @discardableResult
    public func dispatch(key: String, pressed: Bool, source: ControlInputSource = .keyboard) -> Bool {
        if pressed {
            if pressedIn[key] != nil {
                if case .duplicate = heldInputs.press(key, source: source) { repeatedPresses += 1 }
                return true
            }
            let layer = buttonLayer(for: key, in: activeLayer)
            guard let handlers = buttonHandlers[layer]?[key], !handlers.isEmpty else { return false }
            _ = heldInputs.press(key, source: source)
            pressedIn[key] = PressOwnership(layer: layer, registrations: handlers,
                                            transfersMovement: handlers.allSatisfy(\.transfersMovement))
            for registration in handlers { registration.handler(true) }
            return true
        }
        guard let owner = pressedIn[key] else {
            // An up from the old map cannot release a newly mapped button without a down.
            let mapped = buttonHandlers[buttonLayer(for: key, in: activeLayer)]?[key]?.isEmpty == false
            if mapped { orphanReleases += 1 }
            return mapped
        }
        switch heldInputs.release(key, source: source) {
        case .remaining: return true
        case .orphan: orphanReleases += 1; return true
        case .ended:
            pressedIn.removeValue(forKey: key)
            for registration in owner.registrations { registration.handler(false) }
            if owner.registrations.contains(where: \.renewsCamera) {
                for action in layerActions[mouseViewLayer ?? 0] ?? [] {
                    guard let camera = action as? CameraAction,
                          let registration = camera.mouseViewRegistration, ownsMouseView(registration) else { continue }
                    camera.gameplayInteractionFinished()
                }
            }
            return true
        }
    }

    @discardableResult
    public func dispatch(key: String, x: CGFloat, y: CGFloat) -> Bool {
        guard x.isFinite, y.isFinite else { return false }
        for layer in searchOrder {
            for priority in DispatchPriority.allCases {
                if let entry = directionHandlers[layer]?[priority]?.last(where: { $0.key == key }) {
                    entry.handler(x, y)
                    return true
                }
            }
        }
        return false
    }

    /// Motion callers must not classify a camera by a same-named press registration.
    public func motionPriority(for key: String) -> DispatchPriority? {
        for layer in searchOrder {
            for priority in DispatchPriority.allCases where directionHandlers[layer]?[priority]?.contains(where: { $0.key == key }) == true {
                return priority
            }
        }
        return nil
    }

    public func priority(for key: String) -> DispatchPriority? {
        for layer in searchOrder {
            for priority in DispatchPriority.allCases where directionHandlers[layer]?[priority]?.contains(where: { $0.key == key }) == true {
                return priority
            }
            if buttonHandlers[layer]?[key]?.isEmpty == false { return .normal }
        }
        return nil
    }
    public func hasMapping(for key: String) -> Bool { priority(for: key) != nil }
    private var searchOrder: [Layer] { activeLayer == 0 ? [0] : [activeLayer, 0] }
    private func buttonLayer(for key: String, in layer: Layer) -> Layer {
        if layer != 0, buttonHandlers[layer]?[key]?.isEmpty == false { return layer }
        return 0
    }
    public func setWalking(_ walking: Bool) { for action in actions { (action as? KeyJoystickAction)?.setWalking(walking) } }

    public func invalidateAll() {
        for action in actions { action.invalidate() }
        pressedIn.removeAll()
        heldInputs.reset()
    }
    public func invalidateNonButtons() { for action in actions where !action.isButtonLike { action.invalidate() } }

    /// Only actual relative motion handlers qualify. A click named Mouse is not a camera.
    public var usesMouse: Bool {
        mouseView != nil
    }
}

/// Names used by actions and the router (mirrors `KeymapKeyNames` so this file stands alone).
public enum KeymapNames {
    public static let leftMouseButton = "LMB"
    public static let mouseMove = "Mouse"
    public static let scrollWheelScale = "ScrollWheelScale"
    public static let scrollWheelDrag = "ScrollWheelDrag"
    public static let fakeMouse = "FakeMouse"
}
