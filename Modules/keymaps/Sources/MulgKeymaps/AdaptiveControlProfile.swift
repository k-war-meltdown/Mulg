import Foundation

/// Monster Hunter Outlanders (TiMi Studio Group and Capcom, out 29 October 2026). Its bundle ID
/// is not public yet, so it is recognised by name: "outlanders", or a "mhol" component.
public enum MonsterHunterOutlanders {
    public static let name = "Monster Hunter Outlanders"
    /// Keys that open a screen used with the cursor: map, quests, menu, chat.
    public static let menuKeys = ["M", "J", "Esc", "Enter"]

    public static func matches(_ bundleIdentifier: String) -> Bool {
        let id = bundleIdentifier.lowercased()
        return id.contains("outlanders") || id.split(separator: ".").contains { $0 == "mhol" }
    }
}

public enum ControlInteractionStyle: String, Codable, Sendable, CaseIterable {
    case automatic, camera, pointer
}

/// Intent belongs to a map/context, not to a screen size. Unknown optional metadata
/// is ignored so future profile annotations cannot make an otherwise valid map unreadable.
public struct ControlMapProfile: Codable, Sendable, Equatable {
    public var context: String?
    public var interactionStyle: ControlInteractionStyle?
    public var menuKeys: [String]?
    public var layoutGroups: [ControlLayoutGroup]?
    public var sourceURL: String?

    public init(context: String? = nil, interactionStyle: ControlInteractionStyle? = nil,
                menuKeys: [String]? = nil, layoutGroups: [ControlLayoutGroup]? = nil, sourceURL: String? = nil) {
        self.context = context
        self.interactionStyle = interactionStyle
        self.menuKeys = menuKeys
        self.layoutGroups = layoutGroups
        self.sourceURL = sourceURL
    }

    enum CodingKeys: String, CodingKey { case context, interactionStyle, menuKeys, layoutGroups, sourceURL }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        context = (try? c.decodeIfPresent(String.self, forKey: .context)) ?? nil
        interactionStyle = (try? c.decodeIfPresent(ControlInteractionStyle.self, forKey: .interactionStyle)) ?? nil
        menuKeys = (try? c.decodeIfPresent([String].self, forKey: .menuKeys)) ?? nil
        layoutGroups = (try? c.decodeIfPresent([ControlLayoutGroup].self, forKey: .layoutGroups)) ?? nil
        sourceURL = (try? c.decodeIfPresent(String.self, forKey: .sourceURL)) ?? nil
    }
}

public struct ControlLayoutGroup: Codable, Sendable, Equatable {
    public var name: String
    /// Same-layer button/draggable HID codes, retained for existing maps.
    public var keyCodes: [Int]
    /// Exact runtime binding names, including mouse/controller buttons and modifier chords.
    /// When present, these replace key-code membership; the default-code sentinel is ambiguous.
    public var bindingNames: [String]?
    public var horizontalAnchor: KeymapHorizontalAnchor
    public var verticalAnchor: KeymapVerticalAnchor

    public init(name: String, keyCodes: [Int] = [], bindingNames: [String]? = nil,
                horizontalAnchor: KeymapHorizontalAnchor, verticalAnchor: KeymapVerticalAnchor) {
        self.name = name
        self.keyCodes = keyCodes
        self.bindingNames = bindingNames
        self.horizontalAnchor = horizontalAnchor
        self.verticalAnchor = verticalAnchor
    }

    public func contains(_ element: ButtonElement) -> Bool {
        guard let binding = element.bindingName else { return false }
        if let bindingNames { return bindingNames.contains(binding) }
        return element.keyCode != KeymapKeyNames.defaultCode && keyCodes.contains(element.keyCode)
    }

    enum CodingKeys: String, CodingKey { case name, keyCodes, bindingNames, horizontalAnchor, verticalAnchor }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        keyCodes = try c.decodeIfPresent([Int].self, forKey: .keyCodes) ?? []
        bindingNames = try c.decodeIfPresent([String].self, forKey: .bindingNames)
        horizontalAnchor = try c.decode(KeymapHorizontalAnchor.self, forKey: .horizontalAnchor)
        verticalAnchor = try c.decode(KeymapVerticalAnchor.self, forKey: .verticalAnchor)
    }
}
/// Shared by the host and runtime. Catalog recognition selects input policy only:
/// it never invents touch positions, native-controller support or game state.
public struct AdaptiveControlPlan: Sendable, Equatable {
    public let game: String
    public let context: String
    public let family: String
    public let capturesMouse: Bool
    public let hasRelativeCamera: Bool
    public let menuKeys: Set<String>
    public let movementSticks: Int
    public let calibratedSticks: Int
    public let projectedControls: Int
    public let measuredControls: Int
    public let learnedControls: Int
    public let effectiveBindings: Int
    public let shadowedBindings: Int
    public let bindingConflicts: Int

    public static func resolve(_ map: KeymappingData, bundleIdentifier: String,
                               nativeController: Bool = false, hybridController: Bool = false, mouseGyro: Bool = false,
                               activeLayer: Int = 0, bindingGraph: ControlBindingGraph? = nil,
                               interactionStyle: ControlInteractionStyle = .automatic) -> AdaptiveControlPlan {
        let layer = activeLayer > 0 && (map.mulgLayers?.indices.contains(activeLayer - 1) ?? false)
            ? map.mulgLayers?[activeLayer - 1] : nil
        var annotation = map.mulgControlProfile
        if let contextProfile = layer?.mulgControlProfile {
            annotation = ControlMapProfile(context: contextProfile.context ?? annotation?.context,
                interactionStyle: contextProfile.interactionStyle ?? annotation?.interactionStyle,
                menuKeys: contextProfile.menuKeys ?? annotation?.menuKeys,
                layoutGroups: contextProfile.layoutGroups ?? annotation?.layoutGroups,
                sourceURL: contextProfile.sourceURL ?? annotation?.sourceURL)
        }
        let buttons = (layer?.buttonModels ?? []) + (layer?.draggableButtonModels ?? [])
            + map.buttonModels + map.draggableButtonModels
        let graph = bindingGraph ?? ControlBindingGraph(map)
        let effective = graph.effectiveBindings(activeLayer: activeLayer)
        let mouseBinding = graph.motionBinding(for: KeymapKeyNames.mouseMove, activeLayer: activeLayer)
        let mouseCamera = mouseBinding?.address.kind == .camera || mouseBinding?.address.kind == .analogJoystick
        // Virtual-controller mode explicitly maps mouse movement to the right stick.
        // Hybrid mode is resolved from its touch camera instead.
        let nativeCamera = nativeController
        let relative = mouseCamera || nativeCamera || mouseGyro
        let catalog = catalogEntry(bundleIdentifier)
        let style = interactionStyle != .automatic ? interactionStyle : annotation?.interactionStyle ?? .automatic
        let captures: Bool
        switch style {
        case .pointer: captures = false
        case .camera: captures = relative // No mapped camera: don't capture a useless cursor.
        case .automatic: captures = catalog.family == "tactical" ? false : relative
        }

        // Match the action registration names and channels, not editable display labels.
        let mapped = graph.effectivePressKeys(activeLayer: activeLayer)
        var candidates = Set(annotation?.menuKeys ?? catalog.menuKeys)
        if catalog.game == "Genshin Impact", annotation?.menuKeys == nil,
           buttons.contains(where: { $0.keyCode == 15 && $0.transform.xCoord < 0.15 }) { candidates.remove("L") }
        var menus = candidates.intersection(mapped)
        if nativeController || hybridController {
            let bindings = map.mulgControllerBindings ?? []
            let mappedNative = Set(bindings.compactMap { KeymapKeyNames.name(forKeyCode: $0.keyCode) })
            if annotation?.menuKeys != nil { menus = candidates.intersection(mappedNative) }
            else {
                menus = Set(bindings.filter { $0.element == .buttonMenu || $0.element == .buttonOptions }
                    .compactMap { KeymapKeyNames.name(forKeyCode: $0.keyCode) })
            }
        }
        let addresses = Set(effective.map(\.address))
        func layerScope(_ address: ControlBindingAddress) -> KeymapLayer? {
            guard address.layer > 0, let layers = map.mulgLayers,
                  layers.indices.contains(address.layer - 1) else { return nil }
            return layers[address.layer - 1]
        }
        func stick(_ address: ControlBindingAddress) -> JoystickElement? {
            guard address.layer == 0 || layerScope(address) != nil else { return nil }
            let items = address.layer == 0 ? map.joystickModel : layerScope(address)?.joystickModel ?? []
            return items.indices.contains(address.index) ? items[address.index] : nil
        }
        func transform(_ address: ControlBindingAddress) -> KeyModelTransform? {
            guard address.layer == 0 || layerScope(address) != nil else { return nil }
            let scope = layerScope(address)
            switch address.kind {
            case .button, .draggable:
                let items = address.kind == .button ? scope?.buttonModels ?? map.buttonModels
                    : scope?.draggableButtonModels ?? map.draggableButtonModels
                return items.indices.contains(address.index) ? items[address.index].transform : nil
            case .digitalJoystick, .analogJoystick: return stick(address)?.transform
            case .camera:
                let items = scope?.mouseAreaModel ?? map.mouseAreaModel
                return items.indices.contains(address.index) ? items[address.index].transform : nil
            }
        }
        let transforms = addresses.compactMap(transform)
        let movement = addresses.filter { $0.kind == .digitalJoystick || $0.kind == .analogJoystick }
            .compactMap(stick).filter { !$0.isAnalog || $0.keyName != KeymapKeyNames.mouseMove }
        let shadowed = graph.bindings.filter { $0.address.layer == 0 && !effective.contains($0) }.count
        return AdaptiveControlPlan(game: catalog.game, context: annotation?.context ?? "default",
            family: catalog.family, capturesMouse: captures, hasRelativeCamera: relative, menuKeys: menus,
            movementSticks: movement.count,
            calibratedSticks: movement.filter { $0.calibration?.isValid == true || $0.calibrations?.contains(where: \.isValid) == true }.count,
            projectedControls: transforms.filter { $0.hudSamples?.contains(where: { $0.source == .projected }) == true }.count,
            measuredControls: transforms.filter(\.hasObservedHUDSamples).count,
            learnedControls: transforms.filter { $0.hudSamples?.contains(where: { $0.source == .learned }) == true }.count, effectiveBindings: effective.count, shadowedBindings: shadowed, bindingConflicts: graph.conflictCount)
    }

    private static func catalogEntry(_ bundle: String) -> (game: String, family: String, menuKeys: [String]) {
        switch bundle {
        case "com.miHoYo.GenshinImpact", "com.miHoYo.Yuanshen":
            ("Genshin Impact", "action RPG", ["M", "B", "C", "J", "L", "Esc", "F1", "F2", "F3", "F4", "F5", "Enter", "Y", "U", "I", "O", "P", "N"])
        case "com.HoYoverse.hkrpgoversea", "com.miHoYo.hkrpg":
            ("Honkai: Star Rail", "turn-based RPG", ["Esc", "M", "C", "B", "L", "J", "G", "K", "F1", "F3", "F4", "F5", "U", "X"])
        case "com.miHoYo.bh3global":
            ("Honkai Impact 3rd", "action RPG", ["Esc", "J", "M"])
        case "com.HoYoverse.Nap":
            ("Zenless Zone Zero", "action RPG", ["Esc", "C", "F1", "F2", "F3", "F4", "M", "N", "J"])
        case "com.YoStarEN.Arknights", "com.hypergryph.arknights":
            ("Arknights", "tactical", [])
        case "com.riotgames.league.teamfighttactics":
            ("TFT: Teamfight Tactics", "tactical", [])
        case "com.ncsoft.aion2":
            ("AION2", "action MMO", []) // No verified keymap: don't fabricate skill/menu bindings.
        case _ where MonsterHunterOutlanders.matches(bundle):
            (MonsterHunterOutlanders.name, "action RPG", MonsterHunterOutlanders.menuKeys)
        default:
            ("Custom game", "map-driven", [])
        }
    }
}
