import Foundation
import MulgContracts

/// Defaults for Genshin Impact, the reference game (PLAN.md §14.4).
///
/// Touch profiles use the game's touchscreen HUD; recognized community layouts gain
/// aspect-specific samples. Virtual-controller bindings are a separate optional mode.
public enum GenshinDefaults {
    public static let bundleIdentifiers: Set<String> = ["com.miHoYo.GenshinImpact", "com.miHoYo.Yuanshen"]

    public static func applies(to bundleIdentifier: String) -> Bool {
        bundleIdentifiers.contains(bundleIdentifier)
    }

    /// Keys that open a menu with the cursor showing (§14.2): map, inventory, characters,
    /// quests, party setup, Paimon menu, handbook, co-op, wish, battle pass, events, chat.
    public static let menuKeys: Set<String> = [
        "M", "B", "C", "J", "L", "Esc", "F1", "F2", "F3", "F4", "F5", "Enter", "Y", "U", "I", "O", "P", "N"
    ]

    public static func menuKeys(for map: KeymappingData) -> Set<String> {
        let mapped = Set((map.buttonModels + map.draggableButtonModels).map { KeymapKeyNames.name(forKeyCode: $0.keyCode) ?? $0.keyName })
        var keys = menuKeys.intersection(mapped)
        // The fixed-layout map uses L to shoot while aiming, not to open party setup.
        if map.buttonModels.contains(where: { $0.keyCode == 15 && $0.transform.xCoord < 0.15 }) { keys.remove("L") }
        return keys
    }

    /// Keyboard and mouse → virtual controller (keymap codes; mouse buttons are negative).
    public static let controllerBindings: [ControllerBinding] = {
        var bindings: [ControllerBinding] = [
        ControllerBinding(keyCode: 26, element: .leftStickUp),
        ControllerBinding(keyCode: 22, element: .leftStickDown),
        ControllerBinding(keyCode: 4, element: .leftStickLeft),
        ControllerBinding(keyCode: 7, element: .leftStickRight),
        ControllerBinding(keyCode: 44, element: .buttonA),           // jump / climb / glide
        ControllerBinding(keyCode: 225, element: .rightShoulder),   // sprint
        ControllerBinding(keyCode: -2, element: .rightShoulder),
        ControllerBinding(keyCode: -1, element: .buttonB, alternateWhile: .leftTrigger,
                          alternateElement: .rightTrigger),       // normal/charged attack, aimed bow fire
        ControllerBinding(keyCode: 9, element: .buttonX, menuElement: .buttonA), // interact / confirm
        ControllerBinding(keyCode: 10, element: .buttonX),
        ControllerBinding(keyCode: 8, element: .rightTrigger),      // tap / hold aimed skill
        ControllerBinding(keyCode: 20, element: .buttonY),          // burst
        ControllerBinding(keyCode: 21, element: .leftTrigger, toggle: true), // R toggles aim
        ControllerBinding(keyCode: 15, element: .rightTrigger),     // bow fire alias
        ControllerBinding(keyCode: 27, element: .buttonB),          // drop climbing
        ControllerBinding(keyCode: 11, element: .buttonB),          // break frozen
        ControllerBinding(keyCode: 30, element: .dpadUp),
        ControllerBinding(keyCode: 31, element: .dpadRight),
        ControllerBinding(keyCode: 32, element: .dpadLeft),
        ControllerBinding(keyCode: 33, element: .dpadDown),
        ControllerBinding(keyCode: 23, element: .buttonX, chord: [.leftShoulder]), // grapple
        ControllerBinding(keyCode: 29, element: .buttonB, chord: [.leftShoulder]), // gadget
        ControllerBinding(keyCode: 43, element: .dpadLeft, chord: [.leftShoulder]),
        ControllerBinding(keyCode: -3, element: .dpadLeft, chord: [.leftShoulder]),
        ControllerBinding(keyCode: 41, element: .buttonMenu, alternateWhile: .leftTrigger,
                          alternateElement: .buttonB, menuElement: .buttonB),
        ControllerBinding(keyCode: 16, element: .buttonOptions),    // map
        ControllerBinding(keyCode: 40, element: .buttonA),          // menu confirm
        ControllerBinding(keyCode: 42, element: .buttonB),          // menu back
        ControllerBinding(keyCode: 82, element: .leftStickUp),      // native menu navigation
        ControllerBinding(keyCode: 81, element: .leftStickDown),
        ControllerBinding(keyCode: 80, element: .leftStickLeft),
        ControllerBinding(keyCode: 79, element: .leftStickRight)
        ]
        for i in bindings.indices where [30, 31, 32, 33, 16, 41, 44, 27].contains(bindings[i].keyCode) {
            bindings[i].releaseToggles = [.leftTrigger]
        }
        return bindings
    }()

    /// Touch menu shortcuts are not used in native controller mode: their HUD positions
    /// belong to the touchscreen layout. Native menus use Esc, M, arrows, Enter and Backspace.
    public static let controllerMenuKeys: Set<String> = ["M", "Esc"]

    /// Calibrate the imported landscape desktop layout. Explicit anchors avoid guessing
    /// that the center interaction prompt belongs to the combat controls at the right edge.
    public static func desktopTouchLayout(_ imported: KeymappingData) -> KeymappingData {
        var map = imported
        if map.mulgAspectRatio == nil { map.mulgAspectRatio = 16.0 / 9 }
        map.mulgLockAspectRatio = true
        // The wrapper implements hold-Control walking; do not also toggle the native
        // mobile walk button, which would leave walking enabled after Control is released.
        map.buttonModels.removeAll { $0.keyCode == 224 }
        for (alias, source) in [(58, 19), (59, 28), (60, 18), (61, 12), (62, 24), (-3, 43)] {
            if !map.buttonModels.contains(where: { $0.keyCode == alias }),
               var binding = map.buttonModels.first(where: { $0.keyCode == source }) {
                binding.keyCode = alias
                binding.keyName = KeymapKeyNames.name(forKeyCode: alias) ?? "Btn"
                map.buttonModels.append(binding)
            }
        }
        let right: Set<Int> = [-1, -2, 44, 225, 8, 20, 21, 23, 27, 30, 31, 32, 33]
        for i in map.buttonModels.indices {
            let code = map.buttonModels[i].keyCode
            if right.contains(code) { map.buttonModels[i].transform.horizontalAnchor = .right }
            if code == 9 || code == 10 { map.buttonModels[i].transform.horizontalAnchor = .center }
        }
        for i in map.joystickModel.indices {
            map.joystickModel[i].transform.horizontalAnchor = .left
            if map.joystickModel[i].upKeyCode == 26 {
                map.joystickModel[i].mode = .FLOATING
                map.joystickModel[i].activationDelayMilliseconds = 40
                // Match a joystick-sized drag instead of a nearly full-screen glide circle.
                map.joystickModel[i].transform.size = 20
            }
        }
        if let skill = map.buttonModels.first(where: { $0.keyCode == 8 }),
           !map.draggableButtonModels.contains(where: { $0.keyCode == 8 }) {
            map.buttonModels.removeAll { $0.keyCode == 8 }
            map.draggableButtonModels.append(skill)
        }
        for i in map.mouseAreaModel.indices { map.mouseAreaModel[i].transform.horizontalAnchor = .center }
        return map
    }
    /// Keep the existing numeric touch buttons in one right-edge group. Measured group
    /// positions can follow HUD reflow without replacing their original coordinates.
    public static func correctedTouchInputs(_ original: KeymappingData) -> KeymappingData {
        var map = GenshinHUDLayouts.adaptingKnownLayout(original)
        let indices = (30...33).compactMap { code in map.buttonModels.firstIndex { $0.keyCode == code } }
        guard indices.count == 4 else { return map }
        let transforms = indices.map { map.buttonModels[$0].transform }
        guard transforms.allSatisfy({ $0.xCoord > 0.6 && $0.yCoord > 0.1 && $0.yCoord < 0.7 }),
              let minX = transforms.map(\.xCoord).min(), let maxX = transforms.map(\.xCoord).max(),
              maxX - minX < 0.08,
              zip(transforms, transforms.dropFirst()).allSatisfy({ $0.0.yCoord < $0.1.yCoord }) else { return map }
        for i in indices {
            map.buttonModels[i].transform.horizontalAnchor = .right
            map.buttonModels[i].toggle = false
            map.buttonModels[i].tapDurationMilliseconds = 60
        }
        // Group geometry is optional metadata, not a new binding or fixed aspect preset.
        // Never overwrite an authored group or change calibrated targets.
        if !transforms.contains(where: { ($0.hudSamples ?? []).contains { $0.source == .calibrated } }) {
            var profile = map.mulgControlProfile ?? ControlMapProfile()
            let names = indices.compactMap { map.buttonModels[$0].bindingName }
            let party = indices.map { map.buttonModels[$0] }
            if !(profile.layoutGroups ?? []).contains(where: { group in party.contains(where: group.contains) }) {
                profile.layoutGroups = (profile.layoutGroups ?? []) + [ControlLayoutGroup(name: "Party column",
                    bindingNames: names, horizontalAnchor: .right, verticalAnchor: .center)]
                map.mulgControlProfile = profile
            }
        }
        return map
    }

    /// M5 iPad Pro 13-inch is the 4:3 reference. The window may use any shape; anchored
    /// controls follow the actual viewport instead of constraining the window to the map.
    public static func iPadTouchLayout(_ imported: KeymappingData) -> KeymappingData {
        var map = desktopTouchLayout(imported)
        let screen = DeviceScreen.iPadPro13
        map = map.fitted(toWidth: CGFloat(screen.pointWidth), height: CGFloat(screen.pointHeight))
        map.mulgLockAspectRatio = false
        return correctedTouchInputs(map)
    }
    /// Default settings for Genshin in this fork: hold-Option cursor and the menu keys.
    public static func adjust(_ settings: inout ControlsSettings) {
        settings.cursorKeyBehaviour = .hold
        settings.cursorKey = "option"
        settings.walkModifierKey = "control"
    }
}
