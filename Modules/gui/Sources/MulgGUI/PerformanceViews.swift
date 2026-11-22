// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import MulgContracts
import MulgLibrary
import SwiftUI

/// An option's name with, small beside it, when a change reaches a running game.
struct OptionLabel: View {
    let title: String
    let timing: ApplyTiming
    let key: String?
    let owner: ModuleID?
    init(_ title: String, _ timing: ApplyTiming, key: String? = nil, owner: ModuleID? = nil) {
        self.title = title; self.timing = timing; self.key = key; self.owner = owner
    }
    var body: some View {
        GameSettingLabel(title, key: key, timing: timing, owner: owner)
    }
}

/// The Performance tab of a game's settings (PLAN.md §7). The app owns loading and saving;
/// this view edits `settings` and reports when the game needs the Games category.
/// The parts of the performance settings, each its own page in a game's settings.
public enum PerformancePart: Sendable {
    /// Profiles, MetalFX, frame rate, graphics and hardware.
    case graphics
    /// Background play, battery and heat.
    case power
    /// The audio device format.
    case sound
}

public struct PerformanceTab: View {
    @Environment(\.gameSettingsPresentation) private var presentation
    @Binding var settings: GameSettings
    let category: String?
    let setGamesCategory: () -> Void
    let part: PerformancePart

    /// The profile being previewed, and the changes in it the user unticked to keep their own value.
    @State private var preview: PerformanceProfile?
    @State private var kept: Set<String> = []
    /// The settings around the last profile change, so Undo reverts only what the profile changed.
    @State private var lastProfile: (before: GameSettings, after: GameSettings)?
    @State private var warnings: [OnlineWarning.Feature] = []
    @State private var running = false
    @State private var runningStates: [String: String]?

    private var graphicsUnavailable: String? {
        ModuleRow.unavailabilityReason(.graphics, settings: settings, runningStates: runningStates)
    }
    private var displayUnavailable: String? {
        ModuleRow.unavailabilityReason(.display, settings: settings, runningStates: runningStates)
    }

    public init(settings: Binding<GameSettings>, category: String?, setGamesCategory: @escaping () -> Void,
                part: PerformancePart = .graphics) {
        _settings = settings
        self.part = part
        self.category = category
        self.setGamesCategory = setGamesCategory
    }

    private var pendingRestart: [String] {
        guard running, let initial = presentation.runtime?.launch else { return [] }
        return RestartSettings.pending(from: initial, to: settings)
    }

    public var body: some View {
        Form {
            if !pendingRestart.isEmpty {
                Section {
                    Label {
                        Text("Restart the game to apply: \(pendingRestart.joined(separator: ", "))", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                    }
                    .foregroundStyle(.orange)
                }
            }
            switch part {
            case .graphics: graphicsSections
            case .power: powerSections
            case .sound:
                GameAudioOutputSection(settings: $settings.mulg.engine.audioOutput, bundleIdentifier: settings.bundleIdentifier)
            }
        }
        .formStyle(.grouped)
        .onlineWarnings($warnings)
        // The banner is for a running game; a game that opens starts from the settings as they are.
        .task(id: settings.bundleIdentifier) {
            let game = settings.bundleIdentifier
            for await states in GameWatcher.runStateUpdates() {
                let now = states[game] != nil
                guard now != running || (now && runningStates == nil) else { continue }
                running = now
                if running { readRunningStates(ContainerPaths.current().diagnosticsDirectory(for: game)) }
                else { runningStates = nil }
            }
        }
        .task(id: running ? settings.bundleIdentifier : nil) {
            guard running else { runningStates = nil; return }
            let folder = ContainerPaths.current().diagnosticsDirectory(for: settings.bundleIdentifier)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let writes = folderWrites(folder)
            readRunningStates(folder)
            // The game writes several reports here; only startup.json holds the module states.
            let startup = folder.appendingPathComponent("startup.json")
            var stamp = Self.fileStamp(startup)
            for await _ in writes {
                let current = Self.fileStamp(startup)
                guard current != stamp else { continue }
                stamp = current
                readRunningStates(folder)
            }
        }
    }

    /// Profiles, MetalFX, frame rate, graphics and hardware: what decides how the game looks and runs.
    @ViewBuilder private var graphicsSections: some View {
            Section {
                HStack {
                    ForEach(PerformanceProfile.allCases) { profile in
                        Button(profile.title) {
                            preview = profile
                            kept = []
                        }
                    }
                }
                if let preview {
                    previewRows(preview)
                }
                if let lastProfile {
                    Button(String(localized: "Undo last profile change", bundle: .module), systemImage: "arrow.uturn.backward") {
                        settings = SettingsStore.merge(base: lastProfile.after, edited: lastProfile.before, onto: settings)
                        self.lastProfile = nil
                    }
                }
            } header: {
                Text("Profiles", bundle: .module)
            } footer: {
                Text("Profiles leave settings owned by disabled or unavailable modules unchanged.")
            }
            Section {
                Toggle(isOn: metalFX) {
                    Label {
                        OptionLabel(String(localized: "MetalFX upscaling", bundle: .module), .live, key: "mulg.graphics.metalFX.enabled", owner: .graphics)
                    } icon: {
                        Image(systemName: "wand.and.stars")
                    }
                }
                Picker(selection: $settings.mulg.graphics.metalFX.preset) {
                    ForEach(MetalFXPreset.allCases, id: \.self) { preset in
                        Text(verbatim: preset.label).tag(preset)
                    }
                } label: {
                    OptionLabel(String(localized: "Quality", bundle: .module), .live, key: "mulg.graphics.metalFX.preset", owner: .graphics)
                }
                .disabled(!settings.mulg.graphics.metalFX.enabled)
                Toggle(isOn: $settings.mulg.graphics.metalFX.automatic) {
                    OptionLabel(String(localized: "Switch on when the frame rate drops", bundle: .module), .live,
                                key: "mulg.graphics.metalFX.automatic", owner: .graphics)
                }
                .help(String(localized: "When the game stays unevenly below 60 fps (or the frame limit) for 10 seconds, MetalFX switches on until the game restarts.", bundle: .module))
                .disabled(settings.mulg.graphics.metalFX.enabled)
                LabeledContent(String(localized: "Switch in game", bundle: .module),
                               value: Self.symbols(settings.mulg.graphics.metalFX.hotkey))
                if let graphicsUnavailable { Text(graphicsUnavailable).foregroundStyle(.orange) }
            } header: {
                Text("MetalFX", bundle: .module)
            } footer: {
                Text("Render fewer pixels, then upscale to the output resolution.", bundle: .module)
            }
            .disabled(graphicsUnavailable != nil)
            Section(String(localized: "Frame rate", bundle: .module)) {
                Picker(selection: $settings.mulg.display.frameRateCap) {
                    Text("None", bundle: .module).tag(0)
                    ForEach([120, 90, 60, 45, 30], id: \.self) { rate in
                        Text(verbatim: "\(rate) FPS").tag(rate)
                    }
                } label: {
                    OptionLabel(String(localized: "Frame-rate cap", bundle: .module), .live, key: "mulg.display.frameRateCap", owner: .display)
                }
                Text("Unlock 120 FPS for games that stop at 60: the 120 FPS & camera tab.", bundle: .module)
                    .font(.caption).foregroundStyle(.secondary)
                if let displayUnavailable { Text(displayUnavailable).foregroundStyle(.orange) }
            }
            .disabled(displayUnavailable != nil)
            Section {
                Toggle(isOn: Binding(get: { !settings.mulg.identity.effective.matchDeviceCPU },
                                     set: { settings.mulg.identity.matchDeviceCPU = !$0 })) {
                    OptionLabel("Report Mac CPU cores", .restart, key: "mulg.identity.matchDeviceCPU", owner: .identity)
                }
                .disabled(settings.mulg.identity.environmentBypass
                    || ModuleRow.unavailabilityReason(.identity, settings: settings, runningStates: runningStates) != nil)
                if settings.mulg.identity.environmentBypass {
                    Text("Consistent mobile identity reports the selected device's CPU. Turn it off in Compatibility → Bypasses to restore your usual CPU reporting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.mulg.engine.maximizeShaderCompilation) {
                    OptionLabel("Parallel shader compilation", .restart, key: "mulg.engine.maximizeShaderCompilation", owner: .engine)
                }
                Toggle(isOn: $settings.mulg.engine.prioritizeGameThreads) {
                    OptionLabel("Game threads on performance cores first", .restart, key: "mulg.engine.prioritizeGameThreads", owner: .engine)
                }
            } header: {
                Text("Hardware", bundle: .module)
            } footer: {
                Text("Uses the Mac GPU. CPU counts help the game size its worker pool.", bundle: .module)
            }
            Section(String(localized: "Graphics", bundle: .module)) {
                Group {
                    Toggle(isOn: $settings.mulg.graphics.fullResolution) {
                        OptionLabel(String(localized: "Full resolution", bundle: .module), .restart, key: "mulg.graphics.fullResolution", owner: .graphics)
                    }
                    .help(String(localized: "The game renders at the screen's full pixel density even when its engine would choose less. Only MetalFX renders smaller.", bundle: .module))
                    Toggle(isOn: $settings.mulg.graphics.forceRenderResolution) {
                        OptionLabel(String(localized: "Force selected resolution", bundle: .module), .live, key: "mulg.graphics.forceRenderResolution", owner: .graphics)
                    }
                    .help(String(localized: "Overrides the game's own resolution option: it renders at the window's pixel size for the selected resolution. Unity games are set through Unity itself; other games through their render surface. Costs GPU time; turn it off if the picture looks wrong.", bundle: .module))
                    Toggle(isOn: $settings.mulg.graphics.unityHighestQuality) {
                        OptionLabel(String(localized: "Unity: highest quality level", bundle: .module), .live, key: "mulg.graphics.unityHighestQuality", owner: .graphics)
                    }
                    .help(String(localized: "Asks Unity for its highest quality level, the way the game's own options do. Raises shadows, effects and anti-aliasing and can cost frame rate. Unity games that expose their functions only; a game that keeps setting its own level wins.", bundle: .module))
                    .disabled(!settings.mulg.graphics.forceRenderResolution)
                    Toggle(isOn: $settings.mulg.graphics.vsyncOff) {
                        OptionLabel(String(localized: "Disable Vsync", bundle: .module), .live, key: "mulg.graphics.vsyncOff", owner: .graphics)
                    }
                    Toggle(isOn: $settings.mulg.graphics.fullScreenPerformanceMode) {
                        OptionLabel(String(localized: "Full-screen performance mode", bundle: .module), .live, key: "mulg.graphics.fullScreenPerformanceMode", owner: .graphics)
                    }
                    Toggle(isOn: $settings.mulg.graphics.raiseRenderThreadPriority) {
                        OptionLabel(String(localized: "Raise render-thread priority", bundle: .module), .live, key: "mulg.graphics.raiseRenderThreadPriority", owner: .graphics)
                    }
                    Toggle(isOn: $settings.mulg.graphics.shaderArchive) {
                        OptionLabel(String(localized: "Cache compiled shaders", bundle: .module), .restart, key: "mulg.graphics.shaderArchive", owner: .graphics)
                    }
                    Toggle(isOn: $settings.mulg.graphics.justInTimeFrameStart) {
                        OptionLabel(String(localized: "Reduce input latency under FPS cap", bundle: .module), .live, key: "mulg.graphics.justInTimeFrameStart", owner: .graphics)
                    }
                }
                .disabled(graphicsUnavailable != nil)
                if let graphicsUnavailable { Text(graphicsUnavailable).foregroundStyle(.orange) }
                Toggle(isOn: $settings.mulg.display.lowLatency) {
                    OptionLabel(String(localized: "Limit queued frames", bundle: .module), .live, key: "mulg.display.lowLatency", owner: .graphics)
                }
            }
            Section {
                DisclosureGroup("Launch checklist") {
                ForEach(ReadinessCheck.run(.current(category: category), settings: settings)) { check in
                    Label(check.title, systemImage: check.state.symbol)
                        .foregroundStyle(check.state.color)
                }
                }
            }
    }

    /// Background play, battery and heat: what happens when the game is hidden, on battery or hot.
    @ViewBuilder private var powerSections: some View {
            Section {
                Toggle(isOn: $settings.mulg.engine.keepRunningUnfocused) {
                    OptionLabel("Keep playing in background", .live, key: "mulg.engine.keepRunningUnfocused", owner: .engine)
                }
                .accessibilityIdentifier("game.keepRunningUnfocused")
                Toggle(isOn: $settings.mulg.engine.muteWhenUnfocused) {
                    OptionLabel("Mute when not in focus", .live, key: "mulg.engine.muteWhenUnfocused", owner: .engine)
                }
                .help("The game goes silent while you use another app or window, and its sound comes back when you return. Also in the game's Controls menu.")
                Toggle(isOn: $settings.mulg.engine.confirmQuitShortcut) {
                    OptionLabel("Press ⌘Q twice to quit", .live, key: "mulg.engine.confirmQuitShortcut", owner: .engine)
                }
                .help("A single ⌘Q in the game shows a warning instead of quitting. The menu and the Dock still quit at once.")
                Toggle(isOn: $settings.mulg.engine.keepForegroundOnOtherSpaces) {
                    OptionLabel("Keep running on other Spaces", .live, key: "mulg.engine.keepForegroundOnOtherSpaces", owner: .engine)
                }
                .help("Switching from a full-screen game to the desktop or another Space no longer sends it to the background, where games reload, lag or quit. It runs at the hidden-window frame rate until you come back.")
                Toggle(isOn: $settings.mulg.display.backgroundThrottle) {
                    OptionLabel(String(localized: "Throttle hidden windows", bundle: .module), .live, key: "mulg.display.backgroundThrottle", owner: .display)
                }
            } header: {
                Text("Background play")
            } footer: {
                Text("Prevents wrapper background pauses and throttling. Games may still pause themselves.")
            }
            Section(String(localized: "Battery", bundle: .module)) {
                Toggle(isOn: $settings.mulg.display.batterySaverOnBattery) {
                    OptionLabel(String(localized: "Automatic battery saver", bundle: .module), .live, key: "mulg.display.batterySaverOnBattery", owner: .display)
                }
                Picker(selection: $settings.mulg.display.batteryFrameRateCap) {
                    Text(verbatim: "60 FPS").tag(60)
                    Text(verbatim: "30 FPS").tag(30)
                } label: {
                    OptionLabel(String(localized: "Battery saver cap", bundle: .module), .live, key: "mulg.display.batteryFrameRateCap", owner: .display)
                }
                .disabled(!settings.mulg.display.batterySaverOnBattery)
            }
            .disabled(displayUnavailable != nil)
            Section(String(localized: "Heat", bundle: .module)) {
                Toggle(isOn: $settings.mulg.display.thermalGuard) {
                    OptionLabel(String(localized: "Thermal FPS limit", bundle: .module), .live, key: "mulg.display.thermalGuard", owner: .display)
                }
                Picker(selection: $settings.mulg.display.thermalFrameRateCap) {
                    Text(verbatim: "60 FPS").tag(60)
                    Text(verbatim: "30 FPS").tag(30)
                } label: {
                    OptionLabel(String(localized: "Cap while hot", bundle: .module), .live, key: "mulg.display.thermalFrameRateCap", owner: .display)
                }
                .disabled(!settings.mulg.display.thermalGuard)
            }
            .disabled(displayUnavailable != nil)
    }

    /// Identity, size and modification time; an atomic rewrite changes the identity.
    private static func fileStamp(_ file: URL) -> [Int]? {
        var info = stat()
        guard stat(file.path, &info) == 0 else { return nil }
        return [Int(info.st_ino), Int(info.st_size), info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec]
    }

    private func readRunningStates(_ folder: URL) {
        let processes = Set(NSRunningApplication.runningApplications(withBundleIdentifier: settings.bundleIdentifier).map(\.processIdentifier))
        let data = (try? Data(contentsOf: folder.appendingPathComponent("startup.json"))) ?? Data()
        runningStates = ModuleRow.runningStates(from: data, processIdentifiers: processes)
    }

    /// What a profile would change, each with a tick to apply it; unticked values stay as they are.
    @ViewBuilder
    private func previewRows(_ profile: PerformanceProfile) -> some View {
        let changes = self.changes(of: profile)
        Text("Changes for \(profile.title)", bundle: .module).font(.headline)
        if changes.isEmpty {
            Text("This game already matches this profile.", bundle: .module).foregroundStyle(.secondary)
        }
        ForEach(changes) { change in
            Toggle(isOn: Binding(get: { !kept.contains(change.key) }, set: { on in
                if on { kept.remove(change.key) } else { kept.insert(change.key) }
            })) {
                HStack {
                    Text(verbatim: change.title)
                    Spacer()
                    Text(verbatim: "\(change.old) → \(change.new)").foregroundStyle(.secondary)
                }
            }
        }
        if profile == .fps120, PerformancePreset.needsGamesCategory(currentCategory: category) {
            Label(String(localized: "Also sets the Games category and signs the game again.", bundle: .module),
                  systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
        HStack {
            Button(String(localized: "Apply", bundle: .module)) { apply(profile) }
                .buttonStyle(.borderedProminent)
                .disabled(changes.allSatisfy { kept.contains($0.key) })
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) { preview = nil }
        }
    }

    private func changes(of profile: PerformanceProfile) -> [SettingChange] {
        var copy = settings
        return PerformancePreset.apply(profile, to: &copy, batteryCap: settings.mulg.display.batteryFrameRateCap,
                                       runningStates: runningStates)
    }

    /// The MetalFX switch, with the one-time online warning when it is turned on.
    private var metalFX: Binding<Bool> {
        Binding(get: { settings.mulg.graphics.metalFX.enabled }, set: { on in
            settings.mulg.graphics.metalFX.enabled = on
            if on {
                warnings += OnlineWarning.pending([.metalFX], bundleIdentifier: settings.bundleIdentifier)
            }
        })
    }

    /// "option+command+U" as the menu symbols "⌥⌘U".
    static func symbols(_ hotkey: String) -> String {
        let names = ["control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘"]
        return hotkey.split(separator: "+").map { names[$0.lowercased()] ?? $0.uppercased() }.joined()
    }

    private func apply(_ profile: PerformanceProfile) {
        let before = settings
        var after = before
        _ = PerformancePreset.apply(profile, to: &after, batteryCap: before.mulg.display.batteryFrameRateCap,
                                    keeping: kept, runningStates: runningStates)
        settings = after
        // The Games category is not a setting, so Undo leaves it as it is.
        lastProfile = (before, after)
        preview = nil
        kept = []
        guard profile == .fps120 else { return }
        if PerformancePreset.needsGamesCategory(currentCategory: category) {
            setGamesCategory()
        }
        var turnedOn = OnlineWarning.featuresTurnedOn(before: before, after: after)
        if ModuleRow.unavailabilityReason(.identity, settings: after, runningStates: runningStates) == nil,
           !turnedOn.contains(.deviceIdentity) {
            turnedOn.append(.deviceIdentity)  // the preset relies on the spoof even if the ID was already set
        }
        warnings = OnlineWarning.pending(turnedOn, bundleIdentifier: after.bundleIdentifier)
    }
}

/// The game's `engine.environment` variables: the value of a row is edited in place and saved
/// when the field is left or Return is pressed, not on every keystroke.
struct EnvironmentSection: View {
    @Binding var environment: [String: String]
    @State private var name = ""
    @State private var value = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    /// The runtime's own check, so nothing is saved that the game would ignore.
    private var problem: EngineSettings.EnvironmentProblem? {
        trimmedName.isEmpty ? nil : EngineSettings.environmentProblem(name: trimmedName, value: value)
    }
    private var replaced: String? { environment[trimmedName] }
    private var canAdd: Bool { !trimmedName.isEmpty && problem == nil && replaced != value }

    var body: some View {
        Section {
            ForEach(environment.keys.sorted(), id: \.self) { key in
                EnvironmentRow(name: key, value: environment[key] ?? "",
                               save: { environment[key] = $0 }, remove: { environment[key] = nil })
            }
            HStack {
                TextField(String(localized: "Name", bundle: .module), text: $name)
                TextField(String(localized: "Value", bundle: .module), text: $value)
                Button(replaced == nil ? String(localized: "Add", bundle: .module) : String(localized: "Replace", bundle: .module)) {
                    environment[trimmedName] = value
                    (name, value) = ("", "")
                }
                .disabled(!canAdd)
            }
            .font(.body.monospaced())
            if let problem {
                Text(EnvironmentRow.message(for: problem)).font(.caption).foregroundStyle(.red)
            } else if let replaced, replaced != value {
                Text("\(trimmedName) is already set to \"\(replaced)\". Replace changes it.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            OptionLabel(String(localized: "Environment variables", bundle: .module), .restart, key: "mulg.engine.environment", owner: .engine)
        } footer: {
            Text("Set in the game before it starts, for Metal, Unity and other switches. Names starting with DYLD_ are not allowed.", bundle: .module)
        }
    }
}

/// One saved variable: its name, and its value as a text field.
private struct EnvironmentRow: View {
    let name: String
    let value: String
    let save: (String) -> Void
    let remove: () -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(name: String, value: String, save: @escaping (String) -> Void, remove: @escaping () -> Void) {
        self.name = name
        self.value = value
        self.save = save
        self.remove = remove
        _draft = State(initialValue: value)
    }

    private var problem: EngineSettings.EnvironmentProblem? {
        EngineSettings.environmentProblem(name: name, value: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: name).font(.body.monospaced()).textSelection(.enabled)
                Text(verbatim: "=").foregroundStyle(.secondary)
                TextField(String(localized: "Value", bundle: .module), text: $draft)
                    .font(.body.monospaced())
                    .focused($focused)
                    .onSubmit(commit)
                Button(String(localized: "Remove", bundle: .module), systemImage: "minus.circle", action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            if let problem {
                Text(Self.message(for: problem)).font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: focused) { if !focused { commit() } }
        // Another window changed it; never under text being typed.
        .onChange(of: value) { if !focused { draft = value } }
    }

    private func commit() {
        if problem == nil, draft != value {
            save(draft)
        } else if problem != nil {
            draft = value
        }
    }

    static func message(for problem: EngineSettings.EnvironmentProblem) -> String {
        switch problem {
        case .emptyName: String(localized: "The name can't be empty.", bundle: .module)
        case .equalsInName: String(localized: "The name can't contain \"=\".", bundle: .module)
        case .nullCharacter: String(localized: "Names and values can't contain a null character.", bundle: .module)
        case .dyldName: String(localized: "Names starting with DYLD_ are ignored by the game.", bundle: .module)
        }
    }
}

/// The Performance tab for one installed game, reading and writing its settings file itself.
public struct GamePerformanceTab: View {
    let bundleIdentifier: String
    let modularRuntime: Bool
    let part: PerformancePart
    let category: String?
    let setGamesCategory: () -> Void
    let saved: () -> Void

    public init(bundleIdentifier: String, modularRuntime: Bool = true, part: PerformancePart = .graphics, category: String?,
                setGamesCategory: @escaping () -> Void, saved: @escaping () -> Void) {
        self.bundleIdentifier = bundleIdentifier
        self.part = part
        self.modularRuntime = modularRuntime
        self.category = category
        self.setGamesCategory = setGamesCategory
        self.saved = saved
    }

    public var body: some View {
        GameSettingsFile(bundleIdentifier: bundleIdentifier, saved: saved) { settings in
            if modularRuntime {
                PerformanceTab(settings: settings, category: category, setGamesCategory: setGamesCategory, part: part)
            } else {
                Form {
                    switch part {
                    case .sound:
                        GameAudioOutputSection(settings: settings.mulg.engine.audioOutput,
                                               bundleIdentifier: bundleIdentifier, supportedRuntime: false)
                    case .graphics:
                        Toggle(isOn: settings.mulg.display.reportProMotion) {
                            OptionLabel(String(localized: "Report 120 Hz screen", bundle: .module), .restart, key: "mulg.display.reportProMotion", owner: .display)
                        }
                    case .power:
                        EmptyView()
                    }
                    Text("Other performance options require the modular runtime.", bundle: .module)
                        .font(.caption).foregroundStyle(.secondary)
                }.formStyle(.grouped)
            }
        }
    }
}

public struct GameCompatibilityTab: View {
    let bundleIdentifier: String
    let saved: () -> Void
    public init(bundleIdentifier: String, saved: @escaping () -> Void) {
        self.bundleIdentifier = bundleIdentifier; self.saved = saved
    }
    public var body: some View {
        GameSettingsFile(bundleIdentifier: bundleIdentifier, saved: saved) { settings in
            Form {
                CompatibilitySections(settings: settings)
                Section("Modules") {
                    ForEach(ModuleRow.rows(for: settings.wrappedValue)) { row in
                        Toggle(isOn: Binding(get: { row.enabled }, set: { value in
                            var edited = settings.wrappedValue
                            ModuleRow.set(row.module, enabled: value, in: &edited)
                            settings.wrappedValue = edited
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                OptionLabel(row.title, .restart, key: "mulg.engine.disabledModules", owner: row.module)
                                Text(row.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(row.locked).help(row.lockReason ?? row.summary)
                    }
                }
            }.formStyle(.grouped)
        }
    }
}

private struct CompatibilitySections: View {
    @Binding var settings: GameSettings
    var body: some View {
        Group {
            Section {
                Toggle(isOn: $settings.mulg.engine.keepGameSDKVersion) {
                    OptionLabel(String(localized: "Keep original game SDK", bundle: .module), .reinstall, key: "mulg.engine.keepGameSDKVersion", owner: .engine)
                }
            } header: {
                Text("Experiments", bundle: .module)
            } footer: {
                Text("Turn it off and install again if the screen or input breaks.", bundle: .module)
            }
            EnvironmentSection(environment: $settings.mulg.engine.environment)
            Section {
                Toggle(isOn: $settings.mulg.engine.automaticRecovery) {
                    OptionLabel("Automatic launch recovery", .restart, key: "mulg.engine.automaticRecovery", owner: .engine)
                }
                .accessibilityIdentifier("game.automaticRecovery")
            } header: {
                Text("Recovery")
            } footer: {
                Text("Reduces optional modules after repeated failed starts. Changes apply next launch.")
            }
            Section("Closing cloud-connected games") {
                Stepper(value: $settings.mulg.engine.shutdownGraceSeconds, in: 1...30) {
                    OptionLabel("Minimum wait: \(Int(settings.mulg.engine.shutdownGrace)) s", .restart,
                                key: "mulg.engine.shutdownGraceSeconds", owner: .engine)
                }
                Stepper(value: $settings.mulg.engine.shutdownDeadlineSeconds, in: 1...60) {
                    OptionLabel("Task deadline: \(Int(settings.mulg.engine.shutdownDeadline)) s", .restart,
                                key: "mulg.engine.shutdownDeadlineSeconds", owner: .engine)
                }
                Text("Allows background work before closing. Use the game’s save or logout indicator first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The Modules tab for one installed game (PLAN.md §1.5 rule 7), reading and writing its
/// settings file itself.
public struct GameModulesTab: View {
    let bundleIdentifier: String
    let saved: () -> Void

    public init(bundleIdentifier: String, saved: @escaping () -> Void) {
        self.bundleIdentifier = bundleIdentifier
        self.saved = saved
    }

    public var body: some View {
        GameSettingsFile(bundleIdentifier: bundleIdentifier, saved: saved) { settings in
            ModulesPage(settings: settings)
        }
    }
}

/// Save backup, diagnostics export and result sharing for one installed game. `saved` also
/// runs after a restore, which replaces the settings file.
public struct GameServicesTab: View {
    let bundleIdentifier: String
    let saved: () -> Void
    @State private var restoreRevision = 0

    public init(bundleIdentifier: String, saved: @escaping () -> Void) {
        self.bundleIdentifier = bundleIdentifier
        self.saved = saved
    }

    public var body: some View {
        GameSettingsFile(bundleIdentifier: bundleIdentifier, saved: saved, reloadRevision: restoreRevision) { settings in
            Form {
                GameServicesSection(settings: settings.wrappedValue, restored: {
                    saved()
                    restoreRevision += 1
                })
            }
            .formStyle(.grouped)
        }
    }
}

/// The Debugger tab for one installed game (settings `diagnostics.debugger`, PLAN.md §8.3):
/// what the runtime writes to the game's debug.log.
public struct GameDebuggerTab<Leading: View>: View {
    let bundleIdentifier: String
    let saved: () -> Void
    let leading: Leading

    /// `leading`: sections the app adds above the debug log (Metal HUD, LLDB), in the same form.
    public init(bundleIdentifier: String, saved: @escaping () -> Void, @ViewBuilder leading: () -> Leading) {
        self.bundleIdentifier = bundleIdentifier
        self.saved = saved
        self.leading = leading()
    }

    public var body: some View {
        GameSettingsFile(bundleIdentifier: bundleIdentifier, saved: saved) { settings in
            DebuggerForm(diagnostics: settings.mulg.diagnostics,
                         folder: ContainerPaths.current().diagnosticsDirectory(for: bundleIdentifier), leading: leading)
        }
    }
}

public extension GameDebuggerTab where Leading == EmptyView {
    init(bundleIdentifier: String, saved: @escaping () -> Void) {
        self.init(bundleIdentifier: bundleIdentifier, saved: saved) { EmptyView() }
    }
}

struct DebuggerForm<Leading: View>: View {
    @Binding var diagnostics: DiagnosticsSettings
    let folder: URL
    var leading: Leading
    var body: some View {
        Form {
            leading
            Section("Measurements") {
                Toggle(isOn: $diagnostics.performanceOverlay) {
                    OptionLabel("Performance overlay", .restart, key: "mulg.diagnostics.performanceOverlay", owner: .diagnostics)
                }
                Toggle(isOn: $diagnostics.measureInputLatency) {
                    OptionLabel("Measure input latency", .restart, key: "mulg.diagnostics.measureInputLatency", owner: .diagnostics)
                }
                Toggle(isOn: $diagnostics.crashReports) {
                    OptionLabel("Keep crash reports", .restart, key: "mulg.diagnostics.crashReports", owner: .diagnostics)
                }
            }
            Section {
                Toggle(isOn: Binding(get: { diagnostics.debugger }, set: { on in
                    diagnostics.debugger = on
                    // Categories start off for new games; switching the log on picks the useful ones.
                    if on, !diagnostics.debugCPU, !diagnostics.debugGameLog {
                        diagnostics.debugCPU = true
                        diagnostics.debugGameLog = true
                    }
                })) {
                    OptionLabel("Enable debug log", .live, key: "mulg.diagnostics.debugger", owner: .diagnostics)
                }
                Group {
                    Toggle(isOn: $diagnostics.debugCPU) {
                        OptionLabel("CPU, hangs & crashes", .live, key: "mulg.diagnostics.debugCPU", owner: .diagnostics)
                    }
                    Toggle(isOn: $diagnostics.debugGameLog) {
                        OptionLabel("Capture game console", .live, key: "mulg.diagnostics.debugGameLog", owner: .diagnostics)
                    }.help("Logs may contain account information. Review before sharing.")
                }.disabled(!diagnostics.debugger)
            } header: { Text("Debug log") }
              footer: { Text("Takes effect in the running game. Graphics and shader validation switch on at the next launch. Logs can reduce performance.") }
            Section {
                Button("Show logs in Finder") { NSWorkspace.shared.open(folder) }
                    .disabled(!FileManager.default.fileExists(atPath: folder.path))
            }
        }.formStyle(.grouped)
    }
}

extension View {
    /// One alert for every pending online warning: a constant binding could not be dismissed
    /// with Esc, and hid the warnings after the first, which are only ever shown once.
    func onlineWarnings(_ warnings: Binding<[OnlineWarning.Feature]>) -> some View {
        alert(String(localized: "Online games", bundle: .module),
              isPresented: Binding(get: { !warnings.wrappedValue.isEmpty },
                                   set: { if !$0 { warnings.wrappedValue = [] } })) {
            Button(String(localized: "I understand", bundle: .module), role: .cancel) {}
        } message: {
            Text(warnings.wrappedValue.map(OnlineWarning.message(for:)).joined(separator: "\n\n"))
        }
    }
}

/// Loads one game's settings file, shows `content` over it and saves every change.
/// A running game picks up the changes (engine `SettingsChanged`). The app's older settings
/// screen keeps its own copy of the same file, so `saved` tells it to read the file again.
struct GameSettingsFile<Content: View>: View {
    let bundleIdentifier: String
    let saved: () -> Void
    var reloadRevision = 0
    @ViewBuilder let content: (Binding<GameSettings>) -> Content

    @Environment(\.gameSettingsPresentation) private var presentation
    @State private var settings: GameSettings?
    @State private var problem: String?
    @State private var saveProblem: String?

    var body: some View {
        Group {
            if let problem {
                ContentUnavailableView {
                    Label(String(localized: "Settings can't be read", bundle: .module), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(problem)
                } actions: {
                    Button(String(localized: "Try Again", bundle: .module), action: load)
                }
            } else if let settings {
                // Only a user edit writes the file. Reloading another tab's changes must not
                // trigger a second save or overwrite a newer edit on disk.
                content(Binding(get: { self.settings ?? settings }, set: save))
                    .environment(\.gameSettingsPresentation, currentPresentation(settings))
            } else {
                ProgressView()
            }
        }
        // Again on every visit: the other tabs may have written the file meanwhile.
        .onAppear(perform: load)
        .onChange(of: reloadRevision) { load() }
        // And while open: another window, the older settings screen or the running game
        // (a hotkey) can save the same file. Our own saves come back equal and change nothing.
        .task(id: bundleIdentifier) {
            let file = SettingsStore().paths.settingsFile(for: bundleIdentifier)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            for await _ in folderWrites(file.deletingLastPathComponent()) {
                // Writes come in bursts (a slider); one read covers 0.3 s.
                try? await Task.sleep(for: .milliseconds(300))
                reloadIfChanged()
            }
        }
        .alert(String(localized: "Settings couldn't be saved", bundle: .module),
               isPresented: Binding(get: { saveProblem != nil }, set: { if !$0 { saveProblem = nil } })) {
            Button(String(localized: "OK", bundle: .module), role: .cancel) {}
        } message: {
            Text(saveProblem ?? "")
        }
    }

    private func currentPresentation(_ settings: GameSettings) -> GameSettingsPresentation {
        var result = presentation
        result.settings = settings
        return result
    }

    private func save(_ updated: GameSettings) {
        guard problem == nil, let base = settings, updated != base else { return }
        let store = SettingsStore()
        do {
            let merged = try store.save(updated, basedOn: base)
            settings = merged
            saved()
        } catch {
            // Keep the last saved values visible, so a failed toggle never looks applied.
            saveProblem = error.description
        }
    }

    private func load() {
        let loaded = SettingsStore().load(bundleIdentifier: bundleIdentifier)
        // Never edit defaults over a file that could not be read: saving would replace it.
        problem = loaded.problem?.description
        settings = loaded.settings
    }

    /// An outside write. A missing or unreadable file is ignored (a reset, or a write halfway),
    /// so the page never drops to defaults under the user.
    private func reloadIfChanged() {
        guard problem == nil,
              FileManager.default.fileExists(atPath: SettingsStore().paths.settingsFile(for: bundleIdentifier).path) else { return }
        let loaded = SettingsStore().load(bundleIdentifier: bundleIdentifier)
        guard loaded.problem == nil, loaded.settings != settings else { return }
        settings = loaded.settings
        saved()
    }
}

/// Writes to a folder. Settings files are saved atomically (a rename), which shows up as a
/// write to their folder; only the newest pending event is kept.
@MainActor
func folderWrites(_ folder: URL) -> AsyncStream<Void> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return continuation.finish() }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { continuation.yield() }
        source.setCancelHandler { close(descriptor) }
        continuation.onTermination = { _ in source.cancel() }
        source.resume()
    }
}

/// The advanced Modules page: an on/off switch per game-side module (PLAN.md §7).
public struct ModulesPage: View {
    @Binding var settings: GameSettings

    public init(settings: Binding<GameSettings>) {
        _settings = settings
    }

    public var body: some View {
        Form {
            ForEach(ModuleRow.rows(for: settings)) { row in
                Toggle(isOn: Binding(
                    get: { row.enabled },
                    set: { ModuleRow.set(row.module, enabled: $0, in: &settings) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            OptionLabel(row.title, .restart)
                            if row.isExperimental {
                                Text(String(localized: "Experimental", bundle: .module))
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .background(.orange.opacity(0.2), in: Capsule())
                            }
                        }
                        Text(verbatim: row.summary).font(.caption).foregroundStyle(.secondary)
                        if let reason = row.lockReason {
                            Label(reason, systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(row.locked)
            }
        }
        .formStyle(.grouped)
    }
}

extension ReadinessCheck.State {
    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .failed: .red
        }
    }
}

extension ReadinessCheck.Inputs {
    /// This Mac right now.
    @MainActor
    static func current(category: String?) -> Self {
        // Points, as upstream's settings view measures the screen.
        let screen = NSScreen.main
        return Self(
            refreshRate: screen?.maximumFramesPerSecond ?? 60,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            mainScreen: (Int(screen?.frame.width ?? 1920), Int(screen?.frame.height ?? 1080)),
            screenHasNotch: (screen?.safeAreaInsets.top ?? 0) > 0,
            category: category
        )
    }
}
#endif
