import Foundation
import MulgContracts

/// Keyboard/mouse touchscreen defaults based on PianothShaveck's PlayCover 16:9 map, with the
/// four ultimate buttons (7, 8, 9, 0) from the author's later "Universal" calibration of it.
/// The 16:10 and 21:9 samples are projections, not independently measured game layouts: the
/// HUD tracker replaces them with measurements once the game may record its own window.
public enum StarRailDefaults {
    public static func applies(to bundleIdentifier: String) -> Bool {
        ["com.HoYoverse.hkrpgoversea", "com.miHoYo.hkrpg"].contains(bundleIdentifier)
    }

    public static func menuKeys(for map: KeymappingData) -> Set<String> {
        let menus: Set<String> = ["Esc", "M", "C", "B", "L", "J", "G", "K", "F1", "F3", "F4", "F5", "U", "X"]
        let mapped = Set((map.buttonModels + map.draggableButtonModels).map {
            KeymapKeyNames.name(forKeyCode: $0.keyCode) ?? $0.keyName
        })
        return menus.intersection(mapped)
    }

    /// Add samples once to the recognized published layout. Custom profiles and editor
    /// measurements retain their geometry; a resize never projects an already-fitted point.
    public static func adaptiveTouchLayout(_ original: KeymappingData) -> KeymappingData {
        let reference = 16.0 / 9
        guard original.mulgAspectRatio.map({ abs($0 - reference) < 0.001 }) ?? true,
              let stick = original.joystickModel.first(where: { $0.upKeyCode == 26 && !$0.isAnalog }),
              abs(stick.transform.xCoord - 0.16558821201324463) < 0.002,
              abs(stick.transform.yCoord - 0.7785698643437136) < 0.002 else { return original }
        var map = original
        map.mulgAspectRatio = reference
        map.mulgLockAspectRatio = false
        let party: Set<Int> = [30, 31, 32, 33]
        let ultimates: Set<Int> = [36, 37, 38, 39]
        let combat: Set<Int> = [20, 8, -1, -2, 225, 44]
        let leftMenus: Set<Int> = [41, 16, 13, 25, 14, 10]

        func sampled(_ input: KeyModelTransform, horizontal: KeymapHorizontalAnchor,
                     vertical: KeymapVerticalAnchor) -> KeyModelTransform {
            guard !input.hasObservedHUDSamples else { return input }
            var base = input
            base.hudSamples = nil
            base.horizontalAnchor = horizontal
            base.verticalAnchor = vertical
            base.hudSamples = [16.0 / 10, reference, 21.0 / 9].map { aspect in
                let projected = base.fitted(from: reference, to: aspect)
                return ControlHUDSample(aspectRatio: aspect, xCoord: projected.xCoord,
                    yCoord: projected.yCoord, size: projected.size,
                    source: abs(aspect - reference) < 0.001 ? .published : .projected)
            }
            return base
        }
        func button(_ input: ButtonElement) -> ButtonElement {
            var element = input
            let code = element.keyCode
            let horizontal: KeymapHorizontalAnchor
            let vertical: KeymapVerticalAnchor
            if party.contains(code) { horizontal = .right; vertical = .top }
            else if ultimates.contains(code) { horizontal = .left; vertical = .bottom }
            else if combat.contains(code) { horizontal = .right; vertical = .bottom }
            else if code == 9 { horizontal = .center; vertical = .center }
            else if code == 27 { horizontal = .center; vertical = .bottom }
            else if leftMenus.contains(code) { horizontal = .left; vertical = .top }
            else { horizontal = .right; vertical = .top }
            element.transform = sampled(element.transform, horizontal: horizontal, vertical: vertical)
            if party.contains(code) || ultimates.contains(code) {
                element.toggle = false
                element.tapDurationMilliseconds = element.tapDurationMilliseconds ?? 60
            }
            return element
        }
        map.buttonModels = map.buttonModels.map(button)
        map.draggableButtonModels = map.draggableButtonModels.map(button)
        for i in map.joystickModel.indices where map.joystickModel[i].upKeyCode == 26 {
            map.joystickModel[i].transform = sampled(map.joystickModel[i].transform, horizontal: .left, vertical: .bottom)
            map.joystickModel[i].mode = map.joystickModel[i].mode ?? .FLOATING
            map.joystickModel[i].activationDelayMilliseconds = map.joystickModel[i].activationDelayMilliseconds ?? 40
        }
        for i in map.mouseAreaModel.indices {
            map.mouseAreaModel[i].transform = sampled(map.mouseAreaModel[i].transform, horizontal: .center, vertical: .center)
        }
        return map
    }
}
