// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MulgContracts

/// Published touch maps and explicit game contexts. Never overwrite a player's map,
/// calibration or default selection when adding companion contexts.
public enum BundledKeymaps {
    private static func resource(_ name: String) -> KeymappingData? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "mulgmap", subdirectory: "Keymaps"),
              let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListDecoder().decode(KeymappingData.self, from: data))?.withAdaptiveLayouts()
    }

    /// Older bundled revisions of a game's map, kept as `<name>.superseded-<n>`. A player's copy
    /// that still has exactly one revision's controls and positions is replaced by the current
    /// map; a copy with any edit is never touched.
    static func supersededKeymaps(for bundleIdentifier: String) -> [KeymappingData] {
        let name = keymapResourceName(for: bundleIdentifier)
        return (1...16).compactMap { resource("\(name).superseded-\($0)") }
    }

    /// True when `keymap` has the same controls, keys and positions as `older`. Fitting data
    /// (anchors, per-shape samples) and tap flags are ignored: seeding and the resize system add them.
    static func hasSameControls(_ keymap: KeymappingData, as older: KeymappingData) -> Bool {
        func close(_ a: KeyModelTransform, _ b: KeyModelTransform) -> Bool {
            abs(a.xCoord - b.xCoord) < 1e-6 && abs(a.yCoord - b.yCoord) < 1e-6 && abs(a.size - b.size) < 1e-6
        }
        func same(_ a: [ButtonElement], _ b: [ButtonElement]) -> Bool {
            a.count == b.count && a.allSatisfy { x in b.contains { $0.keyCode == x.keyCode && close($0.transform, x.transform) } }
        }
        func sameSticks(_ a: [JoystickElement], _ b: [JoystickElement]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy {
                [$0.upKeyCode, $0.leftKeyCode, $0.downKeyCode, $0.rightKeyCode] == [$1.upKeyCode, $1.leftKeyCode, $1.downKeyCode, $1.rightKeyCode]
                    && close($0.transform, $1.transform)
            }
        }
        func sameAreas(_ a: [MouseAreaElement], _ b: [MouseAreaElement]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { close($0.transform, $1.transform) }
        }
        return (keymap.mulgLayers ?? []).isEmpty
            && same(keymap.buttonModels, older.buttonModels) && same(keymap.draggableButtonModels, older.draggableButtonModels)
            && sameSticks(keymap.joystickModel, older.joystickModel) && sameAreas(keymap.mouseAreaModel, older.mouseAreaModel)
    }

    private static func keymapResourceName(for bundleIdentifier: String) -> String {
        switch bundleIdentifier {
        case "com.miHoYo.hkrpg": "com.HoYoverse.hkrpgoversea"
        case "com.hypergryph.arknights": "com.YoStarEN.Arknights"
        case _ where MonsterHunterOutlanders.matches(bundleIdentifier): "monster-hunter-outlanders"
        default: bundleIdentifier
        }
    }

    static func keymap(for bundleIdentifier: String) -> KeymappingData? {
        resource(keymapResourceName(for: bundleIdentifier))
    }


    /// Seeds an empty default or a shape-only older bundled copy. Contexts are added as
    /// separate maps; the player switches them with the existing keymap shortcuts/list.
    @discardableResult
    public static func seed(_ bundleIdentifier: String, paths: ContainerPaths = .current()) -> Bool {
        guard var bundled = keymap(for: bundleIdentifier) else { return false }
        let loaded = SettingsStore(paths: paths).load(bundleIdentifier: bundleIdentifier)
        guard Self.playsByKeyboard(loaded.settings), loaded.problem == nil else { return false }
        let store = KeymapStore(paths: paths, bundleIdentifier: bundleIdentifier)
        let current = store.loadDefault()
        guard current.problems.isEmpty else { return false }
        bundled.bundleIdentifier = bundleIdentifier
        var wrote = false
        if Self.isEmpty(current.keymap) || Self.lacksShapeOnly(current.keymap, bundled)
            || Self.supersededKeymaps(for: bundleIdentifier).contains(where: { Self.hasSameControls(current.keymap, as: $0) }) {
            wrote = store.write(bundled, to: current.file) == nil
        }
        let selected = wrote ? bundled : current.keymap
        return seedContexts(bundleIdentifier, selected: selected, selectedFile: current.file, store: store) || wrote
    }

    private static func seedContexts(_ bundleIdentifier: String, selected: KeymappingData,
                                     selectedFile: URL, store: KeymapStore) -> Bool {
        guard bundleIdentifier == "com.HoYoverse.Nap",
              var config = try? store.readConfig().get() else { return false }
        var wrote = false
        for context in ["City", "Combat", "Hollow"] {
            let name = context == "Hollow" ? "com.HoYoverse.Nap" : "com.HoYoverse.Nap-\(context)"
            guard var map = resource(name) else { continue }
            map.bundleIdentifier = bundleIdentifier
            // The just-seeded default already holds the Hollow context; don't duplicate it.
            let file = selected.mulgControlProfile?.context == map.mulgControlProfile?.context
                && selected.mulgControlProfile?.sourceURL == map.mulgControlProfile?.sourceURL
                ? selectedFile : store.keymapFile(named: "ZZZ - \(context)")
            if !FileManager.default.fileExists(atPath: file.path) {
                guard store.write(map, to: file) == nil else { continue }
                wrote = true
            }
            guard (try? store.read(file).get()) != nil else { continue }
            if !config.keymapOrder.contains(where: { $0.lastPathComponent == file.lastPathComponent }) {
                config.keymapOrder.append(file)
            }
        }
        if (try? store.readConfig().get()) != config {
            if store.writeConfig(config) == nil { wrote = true }
        }
        return wrote
    }

    static func playsByKeyboard(_ settings: GameSettings) -> Bool {
        settings.keymapping && settings.mulg.controls.playMode == .touch
    }

    static func lacksShapeOnly(_ keymap: KeymappingData, _ bundled: KeymappingData) -> Bool {
        var marked = keymap
        marked.mulgAspectRatio = bundled.mulgAspectRatio
        return keymap.mulgAspectRatio == nil && marked == bundled
    }

    static func isEmpty(_ keymap: KeymappingData) -> Bool {
        !keymap.hasTouchControls && (keymap.mulgControllerBindings ?? []).isEmpty
    }
}
#endif
