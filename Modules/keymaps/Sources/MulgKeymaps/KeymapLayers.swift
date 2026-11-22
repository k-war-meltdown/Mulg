import CoreGraphics
import Foundation

/// A second set of bindings, used while its key is held (PLAN.md §14.5): for example a menu
/// layer, or a vehicle layer with other buttons in the same places.
///
/// While the key is held, a key mapped in the layer does what the layer says; keys the layer
/// does not map keep their normal binding.
public struct KeymapLayer: Codable, Sendable, Equatable {
    public var name: String
    /// The key held to use the layer: a key code (HID usage) or a mouse button code.
    public var holdKeyCode: Int
    public var holdKeyName: String
    public var buttonModels: [ButtonElement] = []
    public var draggableButtonModels: [ButtonElement] = []
    public var joystickModel: [JoystickElement] = []
    public var mouseAreaModel: [MouseAreaElement] = []
    public var mulgControlProfile: ControlMapProfile?

    public init(name: String, holdKeyCode: Int, holdKeyName: String) {
        self.name = name
        self.holdKeyCode = holdKeyCode
        self.holdKeyName = holdKeyName
    }

    enum CodingKeys: String, CodingKey {
        case name, holdKeyCode, holdKeyName, buttonModels, draggableButtonModels, joystickModel, mouseAreaModel, mulgControlProfile
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Layer",
                  holdKeyCode: try c.decode(Int.self, forKey: .holdKeyCode),
                  holdKeyName: try c.decodeIfPresent(String.self, forKey: .holdKeyName) ?? "")
        buttonModels = try c.decodeIfPresent([ButtonElement].self, forKey: .buttonModels) ?? []
        draggableButtonModels = try c.decodeIfPresent([ButtonElement].self, forKey: .draggableButtonModels) ?? []
        joystickModel = try c.decodeIfPresent([JoystickElement].self, forKey: .joystickModel) ?? []
        mouseAreaModel = try c.decodeIfPresent([MouseAreaElement].self, forKey: .mouseAreaModel) ?? []
        mulgControlProfile = try c.decodeIfPresent(ControlMapProfile.self, forKey: .mulgControlProfile)
    }

    /// Whether the layer has a key to hold (a new layer has none until one is pressed).
    public var hasHoldKey: Bool {
        holdKeyCode != KeymapKeyNames.defaultCode && !holdKeyName.isEmpty
    }

    public var isEmpty: Bool {
        buttonModels.isEmpty && draggableButtonModels.isEmpty && joystickModel.isEmpty && mouseAreaModel.isEmpty
    }
}

/// Competing bindings within the same input channel/priority or a conflicting layer hold (§14.5).
public struct KeymapConflict: Sendable, Equatable, CustomStringConvertible {
    /// The input, as keymaps name it ("E", "LMB", "Mouse").
    public let key: String
    /// nil for the base keymap, else the layer's name.
    public let layer: String?
    /// What uses the key, for example ["button", "joystick up"].
    public let uses: [String]

    public var description: String {
        let place = layer.map { " in \($0)" } ?? ""
        return "\(key)\(place): \(uses.joined(separator: ", "))"
    }
}

public enum KeymapConflicts {
    /// Every competing same-layer input registration, and every layer hold key that hides a
    /// normal binding or another layer's key.
    public static func find(in keymap: KeymappingData) -> [KeymapConflict] {
        let graph = ControlBindingGraph(keymap)
        var found: [KeymapConflict] = graph.conflictGroups.compactMap { group in
            guard let binding = group.first else { return nil }
            let layer = binding.address.layer == 0 ? nil : keymap.mulgLayers?[binding.address.layer - 1].name
            let uses = group.map { entry -> String in
                switch entry.address.kind {
                case .button: return "button"
                case .draggable: return "draggable button"
                case .digitalJoystick: return "joystick " + (entry.part ?? "direction")
                case .analogJoystick: return "joystick"
                case .camera: return "camera"
                }
            }
            return KeymapConflict(key: binding.key, layer: layer, uses: uses)
        }
        let baseKeys = graph.effectivePressKeys()
        var holdKeys: [String: String] = [:]
        for layer in keymap.mulgLayers ?? [] {
            guard layer.hasHoldKey else { continue }
            if baseKeys.contains(layer.holdKeyName) {
                found.append(KeymapConflict(key: layer.holdKeyName, layer: nil, uses: ["binding", "hold key of \(layer.name)"]))
            }
            if let other = holdKeys[layer.holdKeyName] {
                found.append(KeymapConflict(key: layer.holdKeyName, layer: nil,
                                                uses: ["hold key of \(other)", "hold key of \(layer.name)"]))
            }
            holdKeys[layer.holdKeyName] = layer.name
        }
        return found
    }

    static func name(for code: Int) -> String {
        if let name = KeymapKeyNames.name(forKeyCode: code) {
            return name
        }
        switch code {
        case KeymapKeyNames.leftMouseCode: return KeymapKeyNames.leftMouseButton
        case KeymapKeyNames.rightMouseCode: return KeymapKeyNames.rightMouseButton
        case KeymapKeyNames.middleMouseCode: return KeymapKeyNames.middleMouseButton
        default: return "Btn\(code)"
        }
    }
}
