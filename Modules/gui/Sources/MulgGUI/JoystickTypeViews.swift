// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import MulgContracts
import SwiftUI

/// One keyboard joystick of the game's current profile, as the app lists it.
struct JoystickTypeRow: Identifiable, Equatable {
    /// 0 for the profile's own controls, n for its layer n.
    let layer: Int
    let index: Int
    let keys: String
    var mode: JoystickMode
    var id: String { "\(layer)-\(index)" }
}

/// Reads and changes the type of each keyboard joystick in the game's current profile: the same
/// switch as J or the Floating toggle in the ⌘K mapper. The profile is backed up before each change.
struct JoystickTypes {
    let store: KeymapStore

    init(bundleIdentifier: String, paths: ContainerPaths = .current()) {
        store = KeymapStore(paths: paths, bundleIdentifier: bundleIdentifier)
    }

    /// The profile the game loads: the configured default, else the first one.
    var currentFile: URL? {
        let files = store.orderedKeymapFiles()
        let named = (try? store.readConfig().get())
            .map { store.keymapFile(named: $0.defaultKm.deletingPathExtension().lastPathComponent) }
        return named.flatMap { files.contains($0) ? $0 : nil } ?? files.first
    }

    func rows() -> [JoystickTypeRow] {
        guard let file = currentFile, let keymap = try? store.read(file).get() else { return [] }
        var rows = Self.rows(keymap.joystickModel, layer: 0)
        for (offset, layer) in (keymap.mulgLayers ?? []).enumerated() {
            rows += Self.rows(layer.joystickModel, layer: offset + 1)
        }
        return rows
    }

    private static func rows(_ sticks: [JoystickElement], layer: Int) -> [JoystickTypeRow] {
        sticks.enumerated().compactMap { index, stick in
            guard !stick.isAnalog else { return nil } // mouse and controller sticks have no touch-down choice
            let keys = [stick.upKeyCode, stick.leftKeyCode, stick.downKeyCode, stick.rightKeyCode]
                .map { KeymapKeyNames.name(forKeyCode: $0) ?? "?" }.joined(separator: " ")
            return JoystickTypeRow(layer: layer, index: index, keys: keys, mode: stick.effectiveMode)
        }
    }

    /// Writes one stick's type. Returns a message when the profile could not be changed.
    func set(_ mode: JoystickMode, for row: JoystickTypeRow) -> String? {
        guard let file = currentFile else { return "No controls profile" }
        guard var keymap = try? store.read(file).get() else { return "The controls profile could not be read" }
        if row.layer == 0 {
            guard keymap.joystickModel.indices.contains(row.index) else { return "The profile changed; reopen this page" }
            keymap.joystickModel[row.index].mode = mode
        } else {
            guard var layers = keymap.mulgLayers, layers.indices.contains(row.layer - 1),
                  layers[row.layer - 1].joystickModel.indices.contains(row.index) else {
                return "The profile changed; reopen this page"
            }
            layers[row.layer - 1].joystickModel[row.index].mode = mode
            keymap.mulgLayers = layers
        }
        _ = store.backUp(file)
        return store.write(keymap, to: file).map { String(describing: $0) }
    }
}

/// The Controls page section: every keyboard joystick with its type.
struct JoystickTypesSection: View {
    let bundleIdentifier: String
    @State private var rows: [JoystickTypeRow] = []
    @State private var problem: String?

    var body: some View {
        Section {
            if rows.isEmpty {
                Text("This profile has no keyboard joystick. Add one with ⌘K in the game: Joystick or Floating joystick.",
                     bundle: .module)
                    .foregroundStyle(.secondary)
            }
            ForEach($rows) { $row in
                Picker(selection: Binding(get: { row.mode }, set: { mode in
                    problem = JoystickTypes(bundleIdentifier: bundleIdentifier).set(mode, for: row)
                    if problem == nil { row.mode = mode }
                })) {
                    Text("Fixed: presses on the stick's spot", bundle: .module).tag(JoystickMode.FIXED)
                    Text("Floating: stick appears where pressed", bundle: .module).tag(JoystickMode.FLOATING)
                } label: {
                    Text(verbatim: row.layer == 0 ? row.keys : "\(row.keys) (layer \(row.layer))")
                }
            }
            if let problem { Text(verbatim: problem).foregroundStyle(.orange) }
        } header: {
            Text("Joysticks", bundle: .module)
        } footer: {
            Text("Match the game's own stick: Fixed when it always sits in one place, Floating when it appears where you touch. Applies when the game next loads this profile.",
                 bundle: .module)
        }
        .onAppear { rows = JoystickTypes(bundleIdentifier: bundleIdentifier).rows() }
    }
}
#endif
