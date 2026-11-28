// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import MulgContracts
import SwiftUI

/// The Controls tab for one installed game, reading and writing its settings file itself.
public struct GameControlsTab: View {
    let bundleIdentifier: String
    let saved: () -> Void
    /// Opens the app's keymap list (create, import, export, duplicate, default).
    let openKeymaps: () -> Void
    /// Starts the game, or brings it forward, so its keymap editor (⌘K) can change the default keymap.
    let editKeymap: () -> Void

    @State private var keymap: KeymapSummary?

    public init(bundleIdentifier: String, saved: @escaping () -> Void, openKeymaps: @escaping () -> Void,
                editKeymap: @escaping () -> Void) {
        self.bundleIdentifier = bundleIdentifier
        self.saved = saved
        self.openKeymaps = openKeymaps
        self.editKeymap = editKeymap
    }

    public var body: some View {
        GameSettingsFile(bundleIdentifier: bundleIdentifier, saved: saved) { settings in
            ControlsTab(settings: settings, keymap: keymap, openKeymaps: openKeymaps, editKeymap: editKeymap)
        }
        // Kept current while open: the Keymaps list and the in-game editor (⌘K) write the folder.
        .task(id: bundleIdentifier) {
            keymap = KeymapSummary(bundleIdentifier: bundleIdentifier)
            let folder = ContainerPaths.current().keymapDirectory(for: bundleIdentifier)
            // Opening the tab never creates the folder, so until a first keymap does, watch its parent.
            while !Task.isCancelled {
                let watched = FileManager.default.fileExists(atPath: folder.path) ? folder : folder.deletingLastPathComponent()
                var created = false
                for await _ in folderWrites(watched) {
                    try? await Task.sleep(for: .milliseconds(300))
                    keymap = KeymapSummary(bundleIdentifier: bundleIdentifier)
                    if watched != folder, FileManager.default.fileExists(atPath: folder.path) {
                        created = true
                        break
                    }
                }
                if !created { break }
            }
        }
    }
}

/// The game's default keymap at a glance. Only reads: opening the tab never creates files.
public struct KeymapSummary {
    public let name: String
    public let controls: Int
    public let keymaps: Int
    public let usesNativeController: Bool
    public let context: String?
    public let pointerOnly: Bool
    public let measuredControls: Int
    public let learnedControls: Int
    public let projectedControls: Int
    public let hudAnchors: Int
    /// Width ÷ height of the screen it was made on; nil until the editor first saves it.
    public let aspect: Double?

    public init?(bundleIdentifier: String, paths: ContainerPaths = .current()) {
        let store = KeymapStore(paths: paths, bundleIdentifier: bundleIdentifier)
        let files = store.orderedKeymapFiles()
        let named = (try? store.readConfig().get())
            .map { store.keymapFile(named: $0.defaultKm.deletingPathExtension().lastPathComponent) }
        guard let file = named.flatMap({ files.contains($0) ? $0 : nil }) ?? files.first,
              let keymap = try? store.read(file).get() else { return nil }
        name = file.deletingPathExtension().lastPathComponent
        controls = keymap.buttonModels.count + keymap.draggableButtonModels.count + keymap.joystickModel.count
            + keymap.mouseAreaModel.count + (keymap.mulgControllerBindings?.count ?? 0) + (keymap.mulgLayers ?? []).reduce(0) {
                $0 + $1.buttonModels.count + $1.draggableButtonModels.count + $1.joystickModel.count + $1.mouseAreaModel.count
            }
        keymaps = files.count
        usesNativeController = !(keymap.mulgControllerBindings ?? []).isEmpty
            && !keymap.hasTouchControls
        aspect = keymap.mulgAspectRatio
        let plan = AdaptiveControlPlan.resolve(keymap, bundleIdentifier: bundleIdentifier)
        context = keymap.mulgControlProfile?.context
        pointerOnly = keymap.mulgControlProfile?.interactionStyle == .pointer
            && keymap.buttonModels.isEmpty && keymap.draggableButtonModels.isEmpty
            && keymap.joystickModel.isEmpty && keymap.mouseAreaModel.isEmpty
        measuredControls = plan.measuredControls
        learnedControls = plan.learnedControls
        projectedControls = plan.projectedControls
        hudAnchors = keymap.validHUDAnchors.count
    }

    /// "16:9", "4:3", "16:10", or the plain ratio for other window shapes.
    public static func shape(_ aspect: Double) -> String {
        for (w, h) in [(16, 9), (4, 3), (16, 10), (3, 2)] where abs(aspect - Double(w) / Double(h)) < 0.02 {
            return "\(w):\(h)"
        }
        return String(format: "%.2f:1", aspect)
    }
}

/// How keyboard, mouse, trackpad and controller reach the game (the controls module,
/// PLAN.md §6.1 and §14). Until now these settings had no screen in the app.
struct ControlsTab: View {
    @Binding var settings: GameSettings
    var keymap: KeymapSummary?
    var openKeymaps: () -> Void = {}
    var editKeymap: () -> Void = {}

    @State private var warnings: [OnlineWarning.Feature] = []

    private var controls: Binding<ControlsSettings> { $settings.mulg.controls }

    /// The play mode, with the one-time online warning when the virtual controller comes on.
    private var playMode: Binding<PlayMode> {
        Binding(get: { settings.mulg.controls.playMode }, set: { mode in
            if mode == .touch { selectTouchControls() }
            else { settings.mulg.controls.playMode = mode }
            if mode != .touch {
                warnings += OnlineWarning.pending([.virtualController], bundleIdentifier: settings.bundleIdentifier)
            }
        })
    }

    private func selectTouchControls() {
        settings.mulg.controls.playMode = .touch
        let store = KeymapStore(paths: .current(), bundleIdentifier: settings.bundleIdentifier)
        let loaded = store.loadTouchDefault()
        if loaded.problems.isEmpty, loaded.keymap.hasTouchControls,
           var config = try? store.readConfig().get() {
            config.defaultKm = loaded.file
            _ = store.writeConfig(config)
        }
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: playMode) {
                    Text("Keyboard & mouse (touchscreen)", bundle: .module).tag(PlayMode.touch)
                    Text("Native controller (requires game support)", bundle: .module).tag(PlayMode.virtualController)
                    Text("Hybrid (camera by touch)", bundle: .module).tag(PlayMode.hybrid)
                } label: { OptionLabel("Play mode", .restart, key: "mulg.controls.playMode", owner: .controls) }
                Section("Control mapper") {
                Slider(value: $settings.mulg.mapper.tintOpacity, in: MapperSettings.tintRange) {
                    OptionLabel("Background dimming", .live, key: "mulg.mapper.tintOpacity", owner: .mapper)
                }
                Toggle(isOn: $settings.mulg.mapper.showTips) {
                    OptionLabel("Show mapping tips", .live, key: "mulg.mapper.showTips", owner: .mapper)
                }
            }

            if settings.mulg.controls.playMode != .touch {
                    Button("Game only offers Touchscreen? Use keyboard & mouse", action: selectTouchControls)
                }
                Picker(selection: controls.interactionStyle) {
                    Text("Automatic from keymap", bundle: .module).tag(ControlInteractionStyle.automatic)
                    Text("Camera when mapped", bundle: .module).tag(ControlInteractionStyle.camera)
                    Text("Keep cursor visible", bundle: .module).tag(ControlInteractionStyle.pointer)
                } label: { OptionLabel("Mouse behaviour", .live, key: "mulg.controls.interactionStyle", owner: .controls) }
                .help("Changes live. Camera mode requires relative mouse input in the selected map. Pointer mode keeps clicks and drags available for strategy games and menus.")
                Toggle(isOn: controls.automaticHUDAnchoring) {
                    OptionLabel("Automatic HUD anchoring", .live, key: "mulg.controls.automaticHUDAnchoring", owner: .controls)
                }
                .disabled(settings.mulg.controls.playMode == .virtualController || keymap?.pointerOnly == true)
                .help("Automatically follows visible controls and HUD groups after resizing, keeping your keys and calibration. No per-control setup is required. macOS may request Screen Recording access for this game.")
                ModifierPicker(title: String(localized: "Cursor key", bundle: .module),
                               selection: controls.cursorKey, key: "mulg.controls.cursorKey")
                Toggle(isOn: controls.trackpadGestures) {
                    OptionLabel("Trackpad touch gestures", .restart, key: "mulg.controls.trackpadGestures", owner: .controls)
                }
                Toggle(isOn: controls.cursorKeySwitchesCamera) {
                    OptionLabel("Cursor key and middle click switch mouse look", .live, key: "mulg.controls.cursorKeySwitchesCamera", owner: .controls)
                }
                .help("On: ⌥ Option or a middle click switches between mouse look (cursor hidden) and the cursor. Off: mouse look always stays on with a camera keymap, and they only switch the edge lock.")
                Toggle(isOn: $settings.mulg.engine.confinePointer) {
                    OptionLabel("Keep mouse inside the game", .live, key: "mulg.engine.confinePointer", owner: .engine)
                }
                .help("When ⌥ Option (Alt) or a middle click shows the cursor or switches the edge lock, the cursor stops at the edge of the game window, windowed or full screen, so clicks, drags and keybinds never land on the desktop or another app. Mouse look is never affected. ⌘Tab and ⌘H stay in the game meanwhile; hold ⌘ and press Q to quit the game.")
            } header: {
                Text("Input", bundle: .module)
            } footer: {
                if settings.mulg.controls.playMode == .virtualController {
                    Text("Requires controller support inside the game. If only Touchscreen is offered, choose Keyboard & mouse.")
                } else if keymap?.pointerOnly == true {
                    Text("Left-click to tap. Hold and drag to move items. Start a new drag after resizing.")
                } else if settings.mulg.controls.automaticHUDAnchoring {
                    Text("Keep Touchscreen selected in game. Tap the cursor key or click the mouse wheel to show the cursor; again to hide it. HUD alignment is automatic; manual movement calibration (⌘⇧C) is optional.")
                } else {
                    Text("Keep Touchscreen selected in game. Tap the cursor key or click the mouse wheel to show the cursor; again to hide it. Enable Automatic HUD anchoring for alignment without setup; manual movement calibration is available with ⌘⇧C.")
                }
            }

            Section {
                if let keymap {
                    LabeledContent(String(localized: "Default keymap", bundle: .module)) {
                        if keymap.pointerOnly { Text("\(keymap.name): click and drag") }
                        else { Text("\(keymap.name): \(keymap.controls) controls", bundle: .module) }
                    }
                    if let context = keymap.context {
                        LabeledContent("Map context", value: context.capitalized)
                    }
                    if !keymap.pointerOnly && !keymap.usesNativeController {
                        LabeledContent("Layout calibration", value: "\(keymap.measuredControls) recorded, \(keymap.learnedControls) learned, \(keymap.projectedControls) projected")
                        LabeledContent("HUD alignment", value: settings.mulg.controls.automaticHUDAnchoring
                            ? "Automatic · \(keymap.hudAnchors) manual overrides" : "Map layout · \(keymap.hudAnchors) manual overrides")
                    }
                    LabeledContent(String(localized: "Made on", bundle: .module)) {
                        if keymap.pointerOnly {
                            Text("Cursor follows the current game viewport")
                        } else if keymap.usesNativeController {
                            Text("Native controller: independent of screen shape", bundle: .module)
                        } else if let aspect = keymap.aspect {
                            Text("A \(KeymapSummary.shape(aspect)) screen", bundle: .module)
                        } else {
                            Text("Not recorded: used as it is on every screen", bundle: .module)
                        }
                    }
                }
                HStack {
                    if keymap != nil {
                        Button(String(localized: "Edit This Keymap", bundle: .module), systemImage: "pencil", action: editKeymap)
                            .help(String(localized: "Opens the game. Press ⌘K in it to edit.", bundle: .module))
                    }
                    Spacer()
                    Button(String(localized: "Keymaps…", bundle: .module), action: openKeymaps)
                }
            } header: {
                Text("Keymap", bundle: .module)
            } footer: {
                Text("HUD anchoring learns visible controls automatically and follows resizing. Hidden or uncertain controls keep the map layout and are retried without setup. Allow Screen Recording if macOS asks. Manual overrides are optional in ⌘K with ⌘⇧A. Import and switch maps in Keymaps; switch contexts with ⌘[ / ⌘].")
            }

            if settings.mulg.controls.playMode != .touch {
                Section {
                    Slider(value: controls.mouseToStick.sensitivity, in: 0.01...0.3) {
                        OptionLabel("Sensitivity", .live, key: "mulg.controls.mouseToStick.sensitivity", owner: .controls)
                    }
                    Slider(value: controls.mouseToStick.exponent, in: 0.5...3) {
                        OptionLabel("Curve", .live, key: "mulg.controls.mouseToStick.exponent", owner: .controls)
                    }
                    Slider(value: controls.mouseToStick.deadzone, in: 0...0.2) {
                        OptionLabel("Dead zone", .live, key: "mulg.controls.mouseToStick.deadzone", owner: .controls)
                    }
                    Slider(value: controls.mouseToStick.decay, in: 0...1) {
                        OptionLabel("Return to centre", .live, key: "mulg.controls.mouseToStick.decay", owner: .controls)
                    }
                    ModifierPicker(title: String(localized: "Walk key (half tilt)", bundle: .module),

                                   selection: controls.walkModifierKey, key: "mulg.controls.walkModifierKey")
                } header: {
                    Text("Mouse to stick", bundle: .module)
                } footer: {
                    Text("Walk key changes apply after restart.", bundle: .module)
                }
            }

            Section {
                Slider(value: controls.controllerSticks.deadzone, in: 0...0.3) {
                        OptionLabel("Dead zone", .live, key: "mulg.controls.controllerSticks.deadzone", owner: .controls)
                }
                Slider(value: controls.controllerSticks.exponent, in: 0.5...3) {
                        OptionLabel("Curve", .live, key: "mulg.controls.controllerSticks.exponent", owner: .controls)
                }
            } header: {
                Text("Controller sticks", bundle: .module)
            } footer: {
                Text("Raise the dead zone for a worn stick that drifts. A curve above the middle makes small tilts finer.", bundle: .module)
            }

            Section(String(localized: "Gyro", bundle: .module)) {
                Picker(selection: controls.gyro.source) {
                    Text("Off", bundle: .module).tag(GyroSource.off)
                    Text("Mouse", bundle: .module).tag(GyroSource.mouse)
                    Text("Keys", bundle: .module).tag(GyroSource.keys)
                    Text("Controller", bundle: .module).tag(GyroSource.controller)
                } label: {
                    OptionLabel("Gyro source", .restart, key: "mulg.controls.gyro.source", owner: .controls)
                }
                if settings.mulg.controls.gyro.source == .mouse {
                    Slider(value: controls.gyro.mouseYawSensitivity, in: 0.0005...0.01) {
                        OptionLabel("Turn speed", .live, key: "mulg.controls.gyro.mouseYawSensitivity", owner: .controls)
                    }
                    Slider(value: controls.gyro.mousePitchSensitivity, in: 0.0005...0.01) {
                        OptionLabel("Tilt speed", .live, key: "mulg.controls.gyro.mousePitchSensitivity", owner: .controls)
                    }
                    Toggle(isOn: controls.gyro.invertPitch) {
                        OptionLabel("Invert tilt", .live, key: "mulg.controls.gyro.invertPitch", owner: .controls)
                    }
                }
                if settings.mulg.controls.gyro.source == .keys {
                    Slider(value: controls.gyro.keyRotationSpeed, in: 15...360) {
                        OptionLabel("Rotation speed", .live, key: "mulg.controls.gyro.keyRotationSpeed", owner: .controls)
                    }
                }
                if settings.mulg.controls.gyro.source != .off {
                    LabeledContent(String(localized: "Level again", bundle: .module),
                                   value: PerformanceTab.symbols(settings.mulg.controls.gyro.recenterHotkey))
                }
            }
        }
        .formStyle(.grouped)
        .onlineWarnings($warnings)
    }
}

/// Picks a modifier key by the name the controls module reads ("option", "control" …).
/// A name set by hand in the file stays selectable.
private struct ModifierPicker: View {
    let title: String
    @Binding var selection: String
    var key: String? = nil

    private static let names = ["option", "control", "shift", "command"]

    var body: some View {
        Picker(selection: $selection) {
            ForEach(Self.names.contains(selection) ? Self.names : Self.names + [selection],
                    id: \.self) { name in
                Text(verbatim: PerformanceTab.symbols(name) + " " + name.capitalized).tag(name)
            }
        } label: { OptionLabel(title, .restart, key: key, owner: .controls) }
    }
}
#endif
