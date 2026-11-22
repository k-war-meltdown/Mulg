import Foundation

public enum ControlBindingKind: String, Codable, Sendable, Hashable {
    case button, draggable, digitalJoystick, analogJoystick, camera
}

public enum ControlBindingChannel: String, Sendable, Hashable { case press, motion }

/// Stable within a decoded map. Resizing never creates a new binding identity.
public struct ControlBindingAddress: Codable, Sendable, Hashable {
    public let layer: Int
    public let kind: ControlBindingKind
    public let index: Int

    public init(layer: Int, kind: ControlBindingKind, index: Int) {
        self.layer = layer; self.kind = kind; self.index = index
    }
}

public struct ControlBinding: Sendable, Equatable {
    public let address: ControlBindingAddress
    public let key: String
    public let channel: ControlBindingChannel
    /// Mirrors static dispatch: analog input before camera input. Held drags are dynamic.
    public let priority: Int
    public let part: String?
}

extension ButtonElement {
    /// Legacy draggable maps store their move source in keyName; newer maps can name
    /// a grab button independently. A normal label is not a controller motion source.
    public var dragMotionBindingName: String {
        if let dragMotionSource, !dragMotionSource.isEmpty { return dragMotionSource }
        if keyName == KeymapKeyNames.mouseMove || KeymapKeyNames.thumbstickNames.contains(keyName) { return keyName }
        return KeymapKeyNames.mouseMove
    }
    /// Use exactly the name the runtime registers. Display labels need not equal bindings.
    public var bindingName: String? {
        if keyCode == KeymapKeyNames.defaultCode { return keyName.isEmpty ? nil : keyName }
        return KeymapKeyNames.name(forKeyCode: keyCode)
    }
}

/// Pure, immutable inventory of actual binding channels and layer fallback. Both the host
/// and runtime can use it without touch APIs, scene recognition or game-specific hooks.
public struct ControlBindingGraph: Sendable {
    public let bindings: [ControlBinding]
    private let presses: [Int: [String: [ControlBinding]]]
    private let motions: [Int: [String: [ControlBinding]]]

    public init(_ map: KeymappingData) {
        var entries: [ControlBinding] = []
        func layer(_ index: Int, buttons: [ButtonElement], drags: [ButtonElement],
                   sticks: [JoystickElement], areas: [MouseAreaElement]) {
            func add(_ key: String?, _ kind: ControlBindingKind, _ element: Int,
                     _ channel: ControlBindingChannel, priority: Int = 1, part: String? = nil) {
                guard let key, !key.isEmpty else { return }
                entries.append(ControlBinding(address: ControlBindingAddress(layer: index, kind: kind, index: element),
                                              key: key, channel: channel, priority: priority, part: part))
            }
            for (i, e) in buttons.enumerated() { add(e.bindingName, .button, i, .press) }
            for (i, e) in drags.enumerated() { add(e.bindingName, .draggable, i, .press) }
            for (i, e) in areas.enumerated() { add(e.keyName, .camera, i, .motion, priority: 2) }
            for (i, e) in sticks.enumerated() {
                if e.isAnalog { add(e.keyName, .analogJoystick, i, .motion) }
                else {
                    for (code, part) in zip([e.upKeyCode, e.downKeyCode, e.leftKeyCode, e.rightKeyCode],
                                            ["up", "down", "left", "right"]) {
                        add(KeymapKeyNames.name(forKeyCode: code), .digitalJoystick, i, .press, part: part)
                    }
                }
            }
        }
        layer(0, buttons: map.buttonModels, drags: map.draggableButtonModels,
              sticks: map.joystickModel, areas: map.mouseAreaModel)
        for (i, e) in (map.mulgLayers ?? []).enumerated() where e.hasHoldKey {
            layer(i + 1, buttons: e.buttonModels, drags: e.draggableButtonModels,
                  sticks: e.joystickModel, areas: e.mouseAreaModel)
        }
        bindings = entries
        var p: [Int: [String: [ControlBinding]]] = [:]
        var m: [Int: [String: [ControlBinding]]] = [:]
        for entry in entries {
            if entry.channel == .press { p[entry.address.layer, default: [:]][entry.key, default: []].append(entry) }
            else { m[entry.address.layer, default: [:]][entry.key, default: []].append(entry) }
        }
        presses = p
        motions = m
    }

    public func pressBindings(for key: String, activeLayer: Int = 0) -> [ControlBinding] {
        if activeLayer > 0, let entries = presses[activeLayer]?[key], !entries.isEmpty { return entries }
        return presses[0]?[key] ?? []
    }

    public func motionBinding(for key: String, activeLayer: Int = 0) -> ControlBinding? {
        let entries = (activeLayer > 0 ? motions[activeLayer]?[key] : nil) ?? motions[0]?[key] ?? []
        guard let priority = entries.map(\.priority).min() else { return nil }
        // At the same static priority, later registration replaces earlier registration.
        return entries.last { $0.priority == priority }
    }

    public func effectiveBindings(activeLayer: Int = 0) -> [ControlBinding] {
        let pressKeys = Set(presses[0]?.keys.map { $0 } ?? []).union(presses[activeLayer]?.keys.map { $0 } ?? [])
        let motionKeys = Set(motions[0]?.keys.map { $0 } ?? []).union(motions[activeLayer]?.keys.map { $0 } ?? [])
        return pressKeys.sorted().flatMap { pressBindings(for: $0, activeLayer: activeLayer) }
            + motionKeys.sorted().compactMap { motionBinding(for: $0, activeLayer: activeLayer) }
    }

    public func effectivePressKeys(activeLayer: Int = 0) -> Set<String> {
        Set(effectiveBindings(activeLayer: activeLayer).filter { $0.channel == .press }.map(\.key))
    }

    /// Press and motion are separate channels. Only equal-priority motion registrations
    /// compete; an analog motion binding intentionally taking precedence over a camera
    /// fallback is not an error. Results stay deterministic in the editor and diagnostics.
    public var conflictGroups: [[ControlBinding]] {
        var groups: [[ControlBinding]] = []
        for layer in presses.keys.sorted() {
            for key in (presses[layer]?.keys.map { $0 } ?? []).sorted() {
                if let entries = presses[layer]?[key], entries.count > 1 { groups.append(entries) }
            }
        }
        for layer in motions.keys.sorted() {
            for key in (motions[layer]?.keys.map { $0 } ?? []).sorted() {
                let priorities = Dictionary(grouping: motions[layer]?[key] ?? [], by: \.priority)
                for priority in priorities.keys.sorted() {
                    if let entries = priorities[priority], entries.count > 1 { groups.append(entries) }
                }
            }
        }
        return groups
    }
    public var conflictCount: Int { conflictGroups.count }
}
