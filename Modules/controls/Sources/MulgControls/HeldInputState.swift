import Foundation

/// Several input backends may hold the same logical binding. Only the first down and
/// final matching up are edges; an orphan release never releases a different source.
public enum ControlInputSource: String, Sendable, Hashable {
    case keyboard, mouse, controller
}

public struct HeldInputState: Sendable, Equatable {
    public enum Press: Sendable { case began, joined, duplicate }
    public enum Release: Sendable { case ended, remaining, orphan }
    private var sources: [String: Set<ControlInputSource>] = [:]

    public init() {}
    public var count: Int { sources.count }

    public mutating func press(_ key: String, source: ControlInputSource) -> Press {
        var held = sources[key] ?? []
        guard held.insert(source).inserted else { return .duplicate }
        let result: Press = held.count == 1 ? .began : .joined
        sources[key] = held
        return result
    }

    public mutating func release(_ key: String, source: ControlInputSource) -> Release {
        guard var held = sources[key], held.remove(source) != nil else { return .orphan }
        if held.isEmpty {
            sources.removeValue(forKey: key)
            return .ended
        }
        sources[key] = held
        return .remaining
    }

    public mutating func reset() { sources.removeAll(keepingCapacity: true) }
}

/// Most recently held context wins. Releasing it restores the prior held context instead
/// of incorrectly falling back to base; releasing a buried hold leaves the active one.
public struct HeldControlLayers: Sendable, Equatable {
    private var order: [Int] = []
    private var sources: [Int: Set<ControlInputSource>] = [:]
    public init() {}
    public var activeLayer: Int { order.last ?? 0 }
    public var count: Int { order.count }
    public mutating func set(_ layer: Int, pressed: Bool, source: ControlInputSource = .keyboard) {
        guard layer > 0 else { return }
        if pressed {
            if sources[layer] == nil { order.append(layer) }
            sources[layer, default: []].insert(source)
        } else {
            guard var held = sources[layer], held.remove(source) != nil else { return }
            if held.isEmpty {
                sources.removeValue(forKey: layer)
                order.removeAll { $0 == layer }
            } else { sources[layer] = held }
        }
    }
    public mutating func reset() {
        order.removeAll(keepingCapacity: true)
        sources.removeAll(keepingCapacity: true)
    }
}
