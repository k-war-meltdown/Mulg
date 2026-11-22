//
//  AppSettingsView.swift
//  Mulg
//
//  Created by Isaac Marovitz on 14/08/2022.
//

import AppKit
import MulgGUI
import MulgContracts
import MulgLibrary
import SwiftUI
@preconcurrency import DataCache

enum BlockingTask {
    case none, mulgKit, introspection, iosFrameworks, applicationCategoryType
}

// swiftlint:disable file_length
struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: AppSettingsVM
    @Binding var showKeymapSheet: Bool
    @State private var section: GameSettingsSection = .display
    /// The sidebar highlight slides between pages.
    @Namespace private var navigationSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var closeView = false
    @State private var appIcon: NSImage?
    @State private var hasRuntime: Bool?
    @State private var hasAlias: Bool?
    @State private var currentTask = BlockingTask.none
    @State private var modularRuntime = false
    @State private var operationError: String?
    @State private var confirmReset = false
    @State private var resetAll = false
    @State private var presentation = GameSettingsPresentation()
    @State private var launchStatus = "No launch recorded"
    @State private var runtimeVersion = "Checking…"
    @State private var profileName = "No keymap selected"
    @State private var starting = false
    @State private var stopping = false
    @State private var stopRequestedAt: Date?
    @State private var lastAttemptFailed = false
    @State private var storage: GameStorageSummary?
    @State private var storageRevision = 0
    @State private var contentRevision = 0

    private var game: MulgGame { viewModel.app }
    private var identifier: String { game.info.bundleIdentifier }
    private var unavailable: Bool { hasRuntime == false }

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            HStack(spacing: 0) {
                navigation
                Divider()
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        MulgIcon(currentPage.symbol, tint: currentPage.tint, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(currentPage.title).font(.title2.weight(.semibold))
                            Text(currentPage.subtitle).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if section == .storage {
                            Button("Refresh") { storageRevision += 1 }
                                .buttonStyle(.borderless).help("Recalculate storage usage.")
                        } else if section.resettable {
                            Button("Reset \(section.tabTitle)…") { resetAll = false; confirmReset = true }
                                .buttonStyle(.borderless).help("Restore this tab's preferences to their defaults.")
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)
                    if currentPage.sections.count > 1 {
                        Picker("", selection: $section) {
                            ForEach(currentPage.sections) { Text($0.tabTitle).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.bottom, 8)
                    }
                    if unavailable && [.play, .input].contains(section.group) {
                        Label("Install a runtime (Compatibility → Runtime) to enable these settings.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange).padding(.horizontal, 20).padding(.bottom, 6)
                    }
                    page.id("\(section.rawValue)-\(contentRevision)")
                        .transition(.opacity)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text(presentation.running ? "Changes save automatically. Badges show runtime status." : "Changes save automatically for the next launch.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Keymaps…", action: openKeymaps)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .environment(\.gameSettingsPresentation, presentation)
        .disabled(currentTask != .none)
        .interactiveDismissDisabled(currentTask != .none)
        .frame(width: 980, height: 730)
        .mulgAppearance().mulgWindowBackground()
        .onChange(of: closeView) { dismiss() }
        .onReceive(game.settings.objectWillChange) { viewModel.objectWillChange.send() }
        .onReceive(game.settings.$persistenceProblem) { if let problem = $0 { operationError = problem } }
        .onChange(of: currentTask) {
            if currentTask == .none { refreshRuntime(); reloadSettings() }
        }
        .task {
            appIcon = DataCache.instance.readImage(forKey: identifier) ?? NSWorkspace.shared.icon(forFile: game.url.path)
            hasAlias = game.hasAlias()
            refreshRuntime()
            while !Task.isCancelled {
                refreshStatus()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .task(id: storageRevision) { await measureStorage() }
        .confirmationDialog(resetAll ? "Reset all game preferences?" : "Reset \u{201C}\(section.tabTitle)\u{201D} preferences?",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset preferences", role: .destructive) { resetPreferences() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Game files, downloads, saves, keymaps and installed plugins are kept.")
        }
        .alert("Couldn't complete the change", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(operationError ?? "") }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().scaledToFit().frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.name).font(.title2.weight(.semibold)).lineLimit(1)
                    Text("Version \(game.info.bundleVersion)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if starting || stopping { ProgressView().controlSize(.small) }
                Button(presentation.running ? "Show game" : "Play", systemImage: "play.fill") { play() }
                    .buttonStyle(.borderedProminent).disabled(starting || stopping || game.isStarting || launchStatus == "Closing…")
                if presentation.running {
                    Button("Stop", systemImage: "stop.fill") { stop() }.disabled(starting || stopping)
                }
            }
            HStack(spacing: 10) {
                fact("Storage", value: storage?.formattedTotal ?? "Calculating…", symbol: "externaldrive")
                fact("Controls", value: profileName, symbol: "keyboard")
                fact("Runtime", value: runtimeVersion, symbol: "shippingbox")
                fact("Recent launch", value: launchStatus, symbol: "clock")
            }
        }
        .padding(20)
    }

    private func fact(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle).help(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Two labelled groups of pages; a page's parts are tabs at its top.
    private var navigation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(GameSettingsPage.Group.allCases) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.rawValue.uppercased())
                            .font(.caption2.weight(.semibold)).tracking(0.6)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.bottom, 4)
                        ForEach(group.pages) { item in navigationButton(item) }
                    }
                }
            }
            .padding(12)
        }
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom) {
            Button("Reset all preferences…") { resetAll = true; confirmReset = true }
                .font(.caption).buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.vertical, 12)
        }
        .frame(width: 214)
    }

    private var currentPage: GameSettingsPage { GameSettingsPage(section) }

    private func navigationButton(_ item: GameSettingsPage) -> some View {
        let selected = currentPage == item
        return Button {
            guard !selected else { return }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { section = item.sections[0] }
        } label: {
            HStack(spacing: 9) {
                MulgIcon(item.symbol, tint: item.tint, size: 22)
                Text(item.title)
            }
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.accentColor : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.14))
                            .matchedGeometryEffect(id: "selection", in: navigationSelection)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder private var page: some View {
        switch section {
        case .display:
            GraphicsView(settings: $viewModel.settings).disabled(unavailable)
        case .graphics, .power, .sound:
            GamePerformanceTab(bundleIdentifier: identifier, modularRuntime: modularRuntime,
                               part: section == .graphics ? .graphics : section == .power ? .power : .sound,
                               category: game.info.applicationCategoryType.rawValue,
                               setGamesCategory: setGamesCategory, saved: performanceSaved).disabled(unavailable)
        case .controls:
            GameControlsTab(bundleIdentifier: identifier, saved: reloadSettings, openKeymaps: openKeymaps, editKeymap: editKeymap)
                .disabled(!modularRuntime)
        case .keymapOptions:
            KeymappingView(settings: $viewModel.settings).disabled(unavailable)
        case .unlocks:
            GameUnlocksTab(bundleIdentifier: identifier, saved: reloadSettings).disabled(!modularRuntime)
        case .storage:
            VStack(spacing: 0) {
                storageLocations
                GameServicesTab(bundleIdentifier: identifier, saved: reloadSettings)
            }
        case .privacy:
            GamePrivacyTab(bundleIdentifier: identifier, saved: reloadSettings).disabled(!modularRuntime)
        case .runtime:
            VStack(spacing: 0) {
                runtimeActions
                GameCompatibilityTab(bundleIdentifier: identifier, saved: reloadSettings).disabled(!modularRuntime)
            }
        case .device:
            DeviceFixesView(settings: $viewModel.settings, hasRuntime: $hasRuntime, task: $currentTask, app: game)
                .disabled(unavailable)
        case .bypasses:
            GameBypassesTab(bundleIdentifier: identifier, saved: reloadSettings).disabled(!modularRuntime)
        case .startup:
            MiscView(settings: $viewModel.settings, closeView: $closeView, hasRuntime: $hasRuntime,
                     hasAlias: $hasAlias, task: $currentTask, app: game,
                     applicationCategoryType: game.info.applicationCategoryType)
        case .debugging:
            if modularRuntime {
                GameDebuggerTab(bundleIdentifier: identifier, saved: reloadSettings) { debuggingBasics }
            } else {
                Form { debuggingBasics }.formStyle(.grouped)
            }
        case .info:
            InfoView(info: game.info, hasRuntime: hasRuntime ?? false)
        }
    }

    /// The app's own debugging switches, shown above the runtime's debug log.
    @ViewBuilder private var debuggingBasics: some View {
        Section {
            Toggle(isOn: $viewModel.settings.openWithLLDB) { GameSettingLabel("Launch with LLDB", key: nil) }
            Toggle(isOn: $viewModel.settings.openLLDBWithTerminal) { GameSettingLabel("Open LLDB in Terminal", key: nil) }
                .disabled(!viewModel.settings.openWithLLDB)
        } header: {
            Text("On-screen and debugger")
        } footer: {
            Text("All off for new games. The HUD and LLDB apply at the next launch.")
        }
    }

    private var runtimeActions: some View {
        HStack {
            // A game still on the retired MulgKit moves at Mulg's start or its next Play; this
            // moves it now.
            Label(modularRuntime ? "Runtime installed" : hasRuntime == true ? "Old runtime (MulgKit), update needed" : "No runtime installed",
                  systemImage: modularRuntime ? "checkmark.circle" : "shippingbox")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            if !modularRuntime {
                Button(hasRuntime == true ? "Update runtime" : "Install runtime") {
                    currentTask = .mulgKit
                    Task {
                        defer { currentTask = .none }
                        do {
                            if game.hasRuntime() { try await GameRuntime.refreshInApp(game.executable) }
                            else { try await GameRuntime.installInIPA(game.executable) }
                        } catch {
                            operationError = error.localizedDescription
                        }
                    }
                }.disabled(!GameRuntime.runtimeAvailable || presentation.running)
            }
        }.padding(.horizontal, 20).padding(.vertical, 8)
    }

    private var storageLocations: some View {
        VStack(alignment: .leading, spacing: 10) {
            location("Application", url: game.url, size: storage?.appBytes)
            location("Downloaded data", url: storage?.dataURL ?? GameStorageSummary.dataLocation(game.url, identifier), size: storage?.dataBytes)
            if let storage, let issue = storage.issue {
                Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Clear cache…") { Task { await Uninstaller.clearCachePopup(game); storageRevision += 1 } }
                    .disabled(presentation.running)
                Spacer()
                Button("Remove game…") {
                    Task {
                        await Uninstaller.uninstallPopup(game)
                        if !FileManager.default.fileExists(atPath: game.url.path) { dismiss() }
                    }
                }.disabled(presentation.running)
                Button("Remove game and all data…", role: .destructive) {
                    Task {
                        await Uninstaller.removeCompletelyPopup(game)
                        if !FileManager.default.fileExists(atPath: game.url.path) { dismiss() }
                    }
                }.disabled(presentation.running)
            }.font(.callout)
        }.padding(.horizontal, 20).padding(.bottom, 12)
    }

    private func location(_ title: String, url: URL, size: Int64?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.callout.weight(.medium))
                    if let size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                }
                Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(url.path)
            }
            Spacer()
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .disabled(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    private func refreshRuntime() {
        hasRuntime = game.hasRuntime()
        modularRuntime = GameRuntime.supportsModularSettings(atURL: game.executable)
    }

    private func refreshStatus() {
        var current = GameSettingsPresentation()
        let store = SettingsStore()
        current.settings = store.load(bundleIdentifier: identifier).settings
        current.modular = modularRuntime
        let processes = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { !$0.isTerminated }
        let pids = Set(processes.map(\.processIdentifier))
        current.running = !processes.isEmpty
        // Closed window or Quit: the game is saving before it exits (the runtime records it).
        let closing = GameWatcher.runStates()[identifier] == .closing
        let folder = store.paths.diagnosticsDirectory(for: identifier)
        if let data = try? Data(contentsOf: folder.appendingPathComponent("startup.json")),
           let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            runtimeVersion = current.settings?.mulg.engine.injectedRuntimeVersion ?? "Unknown"
            if let pid = (report["processIdentifier"] as? NSNumber)?.int32Value, pids.contains(pid),
               let modules = report["modules"] as? [[String: Any]] {
                runtimeVersion = report["mulgVersion"] as? String ?? runtimeVersion
                for module in modules {
                    if let id = module["id"] as? String, let state = module["state"] as? String { current.states[id] = state }
                }
            }
        } else {
            runtimeVersion = current.settings?.mulg.engine.injectedRuntimeVersion ?? (hasRuntime == true ? "MulgKit (update needed)" : "Not installed")
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("settings-runtime.json")),
           let report = try? JSONDecoder().decode(RuntimeSettingsReport.self, from: data), pids.contains(report.processIdentifier) {
            current.runtime = report
        }
        presentation = current
        profileName = KeymapSummary(bundleIdentifier: identifier)?.name ?? "No keymap selected"
        if current.running { launchStatus = stopping || closing ? "Closing…" : starting ? "Starting…" : "Running" }
        else if starting { launchStatus = "Starting…" }
        else if lastAttemptFailed { launchStatus = "Launch failed" }
        else {
            let marker = store.paths.safeModeMarker(for: identifier)
            let data = (try? Data(contentsOf: marker)) ?? (try? Data(contentsOf: marker.appendingPathExtension("last.json")))
            if let data, let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let stage = record["stage"] as? String {
                launchStatus = ["healthy", "closing"].contains(stage) ? "Last session ended" : stage == "running" ? "Reached game runtime" : "Stopped during \(stage)"
            } else { launchStatus = "No launch recorded" }
        }
        if stopping && !current.running { stopping = false }
        let closingTimeout = max(45, (current.settings?.mulg.engine.shutdownDeadline ?? 15) + 15)
        if stopping, let requested = stopRequestedAt, Date.now.timeIntervalSince(requested) > closingTimeout {
            stopping = false
            operationError = "The game is still closing. Check its window before trying again."
        }
    }

    private func play() {
        guard !starting else { return }
        if let running = GameWatcher.process(identifier) { running.activate(); return }
        starting = true
        lastAttemptFailed = false
        Task {
            let launched = await game.launch()
            starting = false
            lastAttemptFailed = !launched
            refreshStatus()
        }
    }

    private func stop() {
        let processes = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { !$0.isTerminated }
        stopping = true
        stopRequestedAt = .now
        var refused = false
        for process in processes where !process.terminate() { refused = true }
        if refused {
            stopping = false
            operationError = "The game declined to close. Quit it from its menu and try again."
        }
    }

    private func editKeymap() {
        if let running = GameWatcher.process(identifier) { running.activate() }
        else { play() }
    }
    private func openKeymaps() { closeView.toggle(); showKeymapSheet = true }
    private func reloadSettings() {
        game.settings.decode()
        viewModel.objectWillChange.send()
        refreshStatus()
    }
    private func performanceSaved() {
        reloadSettings()
    }
    private func resetPreferences() {
        let store = SettingsStore()
        let loaded = store.load(bundleIdentifier: identifier)
        guard loaded.problem == nil else { operationError = loaded.problem?.description; return }
        do {
            var edited = loaded.settings
            if resetAll {
                for item in GameSettingsSection.allCases { try item.reset(&edited) }
                edited.mulg.identity = IdentitySettings()
            }
            else { try section.reset(&edited) }
            _ = try store.save(edited, basedOn: loaded.settings)
            if resetAll || section == .debugging {
                game.settings.openWithLLDB = false
                game.settings.openLLDBWithTerminal = true
            }
            performanceSaved()
            contentRevision += 1
        } catch { operationError = error.localizedDescription }
    }
    private func setGamesCategory() {
        currentTask = .applicationCategoryType
        let app = game
        Task {
            defer { currentTask = .none }
            do { try await Task.detached { try app.setApplicationCategoryType(.games) }.value }
            catch { operationError = error.localizedDescription }
        }
    }
    private func measureStorage() async {
        let url = game.url, id = identifier
        let worker = Task.detached(priority: .utility) { GameStorageSummary.measure(url, id) }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        if !Task.isCancelled { storage = result }
    }
}

private struct GameStorageSummary: Sendable {
    let appBytes: Int64
    let dataBytes: Int64
    let dataURL: URL
    let issue: String?
    var formattedTotal: String {
        let size = ByteCountFormatter.string(fromByteCount: appBytes + dataBytes, countStyle: .file)
        return issue == nil ? size : "\(size) (partial)"
    }
    static func dataLocation(_ app: URL, _ identifier: String) -> URL {
        if let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let recorded = info["MulgGameDataRoot"] as? String, recorded.hasPrefix("/") {
            return URL(fileURLWithPath: recorded, isDirectory: true).appendingPathComponent("Data", isDirectory: true)
        }
        let external = try? GameDataStorage.root(for: app, bundleIdentifier: identifier).appendingPathComponent("Data", isDirectory: true)
        if let external, FileManager.default.fileExists(atPath: external.path) { return external }
        return ContainerPaths.current().gameContainer(for: identifier).appendingPathComponent("Data", isDirectory: true)
    }
    static func measure(_ app: URL, _ identifier: String) -> Self {
        let data = dataLocation(app, identifier)
        let container = ContainerPaths.current().gameContainer(for: identifier).resolvingSymlinksInPath()
        var partial = false
        var countedFiles: Set<String> = []
        var visited: Set<String> = []
        func bytes(_ root: URL) -> Int64 {
            guard FileManager.default.fileExists(atPath: root.path) else { partial = true; return 0 }
            let root = root.resolvingSymlinksInPath()
            let allowed = [root.path, container.path]
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                         .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
            var pending = [root]
            var total: Int64 = 0
            while let next = pending.popLast() {
                guard !Task.isCancelled else { partial = true; break }
                guard visited.insert(next.path).inserted else { continue }
                guard let files = FileManager.default.enumerator(at: next, includingPropertiesForKeys: keys,
                    options: [], errorHandler: { _, _ in partial = true; return true }) else { partial = true; continue }
                for case let file as URL in files {
                    if Task.isCancelled { partial = true; break }
                    guard let values = try? file.resourceValues(forKeys: Set(keys)) else { partial = true; continue }
                    if values.isSymbolicLink == true {
                        files.skipDescendants()
                        let target = file.resolvingSymlinksInPath()
                        guard allowed.contains(where: { target.path == $0 || target.path.hasPrefix($0 + "/") }) else { continue }
                        if (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { pending.append(target) }
                        else if countedFiles.insert(target.path).inserted,
                                let targetValues = try? target.resourceValues(forKeys: Set(keys)) {
                            total += Int64(targetValues.totalFileAllocatedSize ?? targetValues.fileAllocatedSize ?? targetValues.fileSize ?? 0)
                        }
                        continue
                    }
                    if values.isDirectory == true { visited.insert(file.path) }
                    if values.isRegularFile == true, countedFiles.insert(file.path).inserted {
                        total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
                    }
                }
            }
            return total
        }
        let appBytes = bytes(app), dataBytes = bytes(data)
        return Self(appBytes: appBytes, dataBytes: dataBytes, dataURL: data,
                    issue: partial ? "Some storage couldn't be measured. Check drive access, then refresh." : nil)
    }

}

struct KeymappingView: View {
    @Binding var settings: AppSettings
    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.settings.keymapping) {
                    GameSettingLabel("Enable keymapping", key: "keymapping", timing: .restart, owner: .controls)
                }
                Toggle(isOn: $settings.settings.noKMOnInput) {
                    GameSettingLabel("Release controls when typing", key: "noKMOnInput", timing: .restart, owner: .controls)
                }.help("Shows the pointer and stops mapped keys while a text field is active.")
                Toggle(isOn: $settings.settings.enableScrollWheel) {
                    GameSettingLabel("Scroll wheel gestures", key: "enableScrollWheel", timing: .restart, owner: .controls)
                }
                Toggle(isOn: $settings.settings.disableBuiltinMouse) {
                    GameSettingLabel("Disable game's native mouse input", key: "disableBuiltinMouse", timing: .restart, owner: .controls)
                }
                Slider(value: $settings.settings.sensitivity, in: 0...100) {
                    GameSettingLabel("Mouse sensitivity", key: "sensitivity", timing: .restart, owner: .controls)
                }
                LabeledContent("Sensitivity", value: "\(Int(settings.settings.sensitivity))%")
                Toggle(isOn: $settings.settings.limitMotionUpdateFrequency) {
                    GameSettingLabel("Limit motion update frequency", key: "limitMotionUpdateFrequency", timing: .restart, owner: .controls)
                }
            } header: {
                Text("Keyboard & mouse")
            } footer: {
                Text("Keep Touchscreen selected in games using touch keymaps. Advanced mappings are in Mapping & devices.")
            }
        }.formStyle(.grouped)
    }
}

// swiftlint:disable:next type_body_length
struct GraphicsView: View {
    @Binding var settings: AppSettings
    /// graphics.forceRenderResolution lives in the runtime settings, not AppSettingsData.
    @State private var forceResolution = false
    @State private var retina = true
    @State var customWidth = 1920
    @State var customHeight = 1080
    @State var showResolutionWarning = false
    @AppStorage("settings.settings.inverseScreenValues") private var inverseScreenValues = false
    @AppStorage("settings.settings.disableTimeout") private var disableTimeout = false
    @AppStorage("settings.toggle.hideTitleBar") private var hideTitleBar = true
    @AppStorage("settings.toggle.floatingWindow") private var floatingWindow = false
    @AppStorage("settings.settings.displayRotation") private var displayRotation = 0
    static var number: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        return formatter
    }

    @State var customScaler = 2.0
    static var fractionFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 1
        formatter.decimalSeparator = "."
        return formatter
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.settings.resolution) {
                    Text("Off — native screen").tag(0)
                    Text("Automatic").tag(1)
                    Text("1080p").tag(2)
                    Text("1440p").tag(3)
                    Text("2160p").tag(4)
                    Text("Custom").tag(5)
                    Text("Resizable").tag(6)
                    Text("iPad screen — exact device pixels").tag(7)
                    Text("4K — exactly 3840 × 2160").tag(8)
                    Text("5K — exactly 5120 × 2880").tag(9)
                    Text("This display — native pixels and Hz").tag(10)
                } label: { GameSettingLabel("Resolution", key: "resolution", timing: .restart, owner: .display) }
                if settings.settings.resolution == 1 {
                    LabeledContent("Detected display", value: detectedDisplay)
                }
                if settings.settings.resolution == 5 {
                    HStack {
                        TextField("Width", value: $customWidth, formatter: Self.number)
                        Text("×").foregroundStyle(.secondary)
                        TextField("Height", value: $customHeight, formatter: Self.number)
                        GameSettingBadge("windowWidth", timing: .restart, owner: .display)
                    }.textFieldStyle(.roundedBorder)
                }
                if [2, 3, 4].contains(settings.settings.resolution) {
                    Picker(selection: $settings.settings.aspectRatio) {
                        Text("4:3").tag(0); Text("16:9").tag(1); Text("16:10").tag(2)
                    } label: { GameSettingLabel("Proportions", key: "aspectRatio", owner: .display) }
                }
                HStack {
                    GameSettingLabel("Render scale", key: "customScaler", owner: .display)
                    Spacer()
                    Stepper(value: $customScaler, in: 0.5...4, step: 0.1) {
                        Text(customScaler, format: .number.precision(.fractionLength(1)))
                    }.fixedSize()
                }.disabled(renderScaleLocked)
                .help("Pixels per logical point for modes that allow a custom scale. A 2.0 scale draws two pixels per point on each axis. The game may independently limit its internal 3D rendering resolution.")
                RetinaToggle(bundleIdentifier: settings.settings.bundleIdentifier, retina: $retina)
                Text("Retina uses the selected display's pixel density. Turn it off to render at one pixel per point. Restart the game after changing it.")
                    .font(.caption).foregroundStyle(.secondary)
                if showResolutionWarning {
                    Label("High render load may reduce performance.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle(isOn: Binding(get: { forceResolution }, set: { forced in
                    forceResolution = forced
                    try? GameActions().setForcesRenderResolution(forced, for: settings.settings.bundleIdentifier)
                })) {
                    GameSettingLabel("Force this resolution in the game", key: "mulg.graphics.forceRenderResolution", timing: .live, owner: .graphics)
                }
                .help("Requests the selected output size. The game may use a smaller internal 3D scene. Turn it off if a game's picture looks wrong.")
                .onAppear { forceResolution = GameActions().forcesRenderResolution(settings.settings.bundleIdentifier) }
                NativeSceneResolutionToggle(bundleIdentifier: settings.settings.bundleIdentifier)
            } header: {
                Text("Render resolution")
            } footer: {
                Text("Automatic uses the window's own pixels. With Retina on, 1080p, 1440p and 2160p target that many pixels tall at the window's shape; iPad, 4K, 5K and This display target their specified pixels. Full screen adds black bars when the shape differs. The output size and internal 3D scene size can differ.")
            }
            Section("Window") {
                if settings.settings.resolution == 6 {
                    Picker(selection: $settings.settings.resizableAspectRatioType) {
                        Text("Free").tag(0); Text("Custom").tag(1)
                        Text("4:3").tag(2); Text("16:9").tag(3); Text("16:10").tag(4)
                    } label: { GameSettingLabel("Window proportions", key: "resizableAspectRatioType", owner: .display) }
                    if settings.settings.resizableAspectRatioType == 1 {
                        HStack {
                            TextField("Width ratio", value: $settings.settings.resizableAspectRatioWidth, formatter: Self.number)
                            Text(":")
                            TextField("Height ratio", value: $settings.settings.resizableAspectRatioHeight, formatter: Self.number)
                        }.textFieldStyle(.roundedBorder)
                    }
                }
                Picker(selection: $settings.settings.displayRotation) {
                    Text("Default").tag(0); Text("Portrait").tag(1)
                    Text("Landscape right").tag(2); Text("Portrait upside down").tag(3); Text("Flip correction").tag(4)
                } label: { GameSettingLabel("Orientation", key: "displayRotation", owner: .display) }
                Toggle(isOn: $settings.settings.hideTitleBar) {
                    GameSettingLabel("Hide title bar", key: "hideTitleBar", owner: .display)
                }
                Toggle(isOn: $settings.settings.floatingWindow) {
                    GameSettingLabel("Keep window on top", key: "floatingWindow", owner: .display)
                }
                Toggle(isOn: $settings.settings.disableTimeout) {
                    GameSettingLabel("Prevent display sleep", key: "disableTimeout", owner: .display)
                }
            }
            Section {
                Toggle(isOn: $settings.settings.inverseScreenValues) {
                    GameSettingLabel("Swap screen dimensions", key: "inverseScreenValues", owner: .display)
                }.onChange(of: settings.settings.inverseScreenValues) { settings.settings.windowFixMethod = 0 }
                Picker(selection: $settings.settings.windowFixMethod) {
                    Text("settings.picker.windowFixMethod.0").tag(0)
                    Text("settings.picker.windowFixMethod.1").tag(1)
                } label: { GameSettingLabel("Correction method", key: "windowFixMethod", owner: .display) }
                    .disabled(!settings.settings.inverseScreenValues || settings.settings.resolution != 0)
            } header: {
                Text("Window correction")
            } footer: { Text("Use only for games with incorrect orientation or window dimensions.") }
        }
        .formStyle(.grouped)
        .onAppear {
            customWidth = settings.settings.windowWidth
            customHeight = settings.settings.windowHeight
            customScaler = settings.settings.customScaler
        }
        .onChange(of: settings.settings.resolution) { setResolution() }
        .onChange(of: settings.settings.aspectRatio) { setResolution() }
        .onChange(of: settings.settings.iosDeviceModel) {
            if settings.settings.resolution == ResolutionMode.matchDevice.rawValue { setResolution() }
        }
        .onChange(of: customWidth) { setResolution() }
        .onChange(of: customHeight) { setResolution() }
        .onChange(of: customScaler) { setResolution() }
        .onChange(of: settings.settings.resizableAspectRatioType) { setAspectRatioForResizableWindow() }
    }

    /// Render scale is fixed by the mode, or 1x while Retina is off.
    private var renderScaleLocked: Bool {
        let mode: Int = settings.settings.resolution
        let retina: Bool = self.retina
        return (1...4).contains(mode) || mode >= 7 || !retina
    }

    private var detectedDisplay: String {
        let width = Int(NSScreen.main?.frame.width ?? 1920)
        let height = Int(NSScreen.main?.frame.height ?? 1080)
        return "\(width) × \(height) points"
    }

    func setResolution() {
        let mode = ResolutionMode(setting: settings.settings.resolution)
        let device = DeviceScreen.forDevice(settings.settings.iosDeviceModel)
        let size = ResolutionCalculator.windowSize(mode: mode,
            aspect: AspectRatioChoice(setting: settings.settings.aspectRatio),
            mainScreen: (Int(NSScreen.main?.frame.width ?? 1920), Int(NSScreen.main?.frame.height ?? 1080)),
            screenHasNotch: NSScreen.hasNotch(),
            custom: (min(max(customWidth, 320), 16384), min(max(customHeight, 240), 16384)), device: device)
        if mode == .matchDevice { customScaler = device.scale }
        else if let fixed = mode.fixedScale { customScaler = fixed }
        else if mode == .display || mode == .auto, let screen = NSScreen.main {
            // Automatic renders the window's real pixels: the screen's own scale, not a chosen one.
            customScaler = screen.backingScaleFactor
        }
        settings.settings.windowWidth = size.width
        settings.settings.windowHeight = size.height
        settings.settings.customScaler = customScaler
        showResolutionWarning = ResolutionCalculator.exceedsWarning(width: size.width, height: size.height, scaler: customScaler)
    }

    func getWidthFromAspectRatio(_ height: Int) -> Int {
        var widthRatio: Int
        var heightRatio: Int

        switch settings.settings.aspectRatio {
        case 0:
            widthRatio = 4
            heightRatio = 3
        case 1:
            widthRatio = 16
            heightRatio = 9
        case 2:
            widthRatio = 16
            heightRatio = 10
        default:
            widthRatio = 16
            heightRatio = 9
        }
        return (height / heightRatio) * widthRatio
    }
    func getHeightForNotch(_ width: Int, _ height: Int) -> Int {
        let wFloat = Float(width)
        let hFloat = Float(height)
        if NSScreen.hasNotch() && (hFloat/wFloat)*16.0 > 10.3 && (hFloat/wFloat)*16.0 < 10.4 {
            return Int((wFloat / 16) * 10)
        } else {
            return Int(height)
        }
    }

    func setAspectRatioForResizableWindow() {
        var widthRatio = 0
        var heightRatio = 0

        switch settings.settings.resizableAspectRatioType {
        // Aspect ratio = Free
        case 0:
            widthRatio = 0
            heightRatio = 0
        // Aspect ratio = Custom
        case 1:
            widthRatio = settings.settings.resizableAspectRatioWidth
            heightRatio = settings.settings.resizableAspectRatioHeight
        // Aspect ratio = 4:3
        case 2:
            widthRatio = 4
            heightRatio = 3
        // Aspect ratio = 16:9
        case 3:
            widthRatio = 16
            heightRatio = 9
        // Aspect ratio = 16:10
        case 4:
            widthRatio = 16
            heightRatio = 10
        default:
            widthRatio = 16
            heightRatio = 9
        }

        settings.settings.resizableAspectRatioWidth = widthRatio
        settings.settings.resizableAspectRatioHeight = heightRatio
    }
}

struct DeviceFixesView: View {
    @Environment(\.gameSettingsPresentation) private var presentation
    @Binding var settings: AppSettings
    @Binding var hasRuntime: Bool?
    @Binding var task: BlockingTask
    @AppStorage("settings.settings.mulgChain") private var mulgChain = false
    @AppStorage("settings.settings.mulgChainDebugging") private var mulgChainDebugging = false
    @State private var hasIntrospection: Bool
    @State private var hasIosFrameworks: Bool
    @State private var loaderError: String?

    var app: MulgGame

    init(settings: Binding<AppSettings>,
         hasRuntime: Binding<Bool?>,
         task: Binding<BlockingTask>,
         app: MulgGame) {
        self._settings = settings
        self._hasRuntime = hasRuntime
        self._task = task
        self.app = app

        let lsEnvironment = app.info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? ""
        self.hasIntrospection = lsEnvironment.contains(MulgGame.introspection)
        self.hasIosFrameworks = lsEnvironment.contains(MulgGame.iosFrameworks)
    }

    var body: some View {
        Form {
            Section("Device identity") {
                Picker(selection: $settings.settings.iosDeviceModel) {
                    ForEach(MobileDeviceCatalog.all) { profile in
                        Text(profile.configured(presentation.settings?.mulg.identity.deviceConfiguration ?? .standard).pickerLabel)
                            .tag(profile.id)
                    }
                    if MobileDeviceCatalog.profile(for: settings.settings.iosDeviceModel) == nil {
                        Text("Custom: \(settings.settings.iosDeviceModel)").tag(settings.settings.iosDeviceModel)
                    }
                } label: { GameSettingLabel("Reported device", key: "iosDeviceModel", owner: .identity) }
            }
            GameLoginSupportSection(gameURL: app.url, bundleIdentifier: app.info.bundleIdentifier)
            Section("Compatibility fixes") {
                Toggle(isOn: Binding(get: { hasIntrospection }, set: { changeLoader($0, path: MulgGame.introspection) })) {
                    GameSettingLabel("Introspection library", key: nil)
                }.toggleStyle(.async($task, role: .introspection)).help("settings.toggle.introspection.help")
                Toggle(isOn: Binding(get: { hasIosFrameworks }, set: { changeLoader($0, path: MulgGame.iosFrameworks) })) {
                    GameSettingLabel("iOS frameworks", key: nil)
                }.toggleStyle(.async($task, role: .iosFrameworks)).help("settings.toggle.iosFrameworks.help")
                Toggle(isOn: $settings.settings.checkMicPermissionSync) {
                    GameSettingLabel("Synchronous microphone permission check", key: "checkMicPermissionSync", owner: .engine)
                }.help("settings.toggle.checkMicPermissionSync.help")
                Toggle(isOn: $settings.settings.blockSleepSpamming) {
                    GameSettingLabel("Block repeated sleep requests", key: "blockSleepSpamming", owner: .engine)
                }.help("settings.toggle.blockSleepSpamming.help")
            }
        }.formStyle(.grouped)
        .alert("Loader change failed", isPresented: Binding(get: { loaderError != nil }, set: { if !$0 { loaderError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(loaderError ?? "") }
    }

    private func changeLoader(_ enabled: Bool, path: String) {
        guard task == .none else { return }
        let introspection = path == MulgGame.introspection
        if introspection { hasIntrospection = enabled } else { hasIosFrameworks = enabled }
        task = introspection ? .introspection : .iosFrameworks
        Task {
            defer { task = .none }
            let actual: Bool
            do { actual = try await Task.detached { try await app.changeDyldLibraryPath(set: enabled, path: path) }.value }
            catch {
                actual = (app.info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? "").split(separator: ":").contains(Substring(path))
                loaderError = error.localizedDescription
            }
            if introspection { hasIntrospection = actual } else { hasIosFrameworks = actual }
        }
    }
}

struct MiscView: View {
    @Binding var settings: AppSettings
    @Binding var closeView: Bool
    @Binding var hasRuntime: Bool?
    @Binding var hasAlias: Bool?
    @Binding var task: BlockingTask
    @AppStorage("settings.settings.discordActivity.enable") private var discordActivity = false
    @AppStorage("settings.openWithLLDB") private var openWithLLDB = false
    @AppStorage("settings.openLLDBWithTerminal") private var openLLDBWithTerminal = false
    @AppStorage("settings.customPluginsWarningShown") private var hasShownCustomPluginWarning = false
    @State var showPopover = false
    @State private var userDylibs: [URL] = []
    @State private var showCustomPluginWarning = false
    @State private var categoryError: String?
    @State private var confirmRuntimeRemoval = false
    var app: MulgGame
    @State var applicationCategoryType: LSApplicationCategoryType
    var body: some View {
        Form {
            Section("Application") {
                Picker(selection: Binding(get: { applicationCategoryType }, set: changeCategory)) {
                    ForEach(LSApplicationCategoryType.allCases, id: \.rawValue) { value in
                        Text(value.localizedName).tag(value)
                    }
                } label: { GameSettingLabel("macOS category", key: nil) }
                    .help("Changing the category updates and re-signs the app. Games enables macOS Game Mode eligibility.")
            }
            Section("Discord") {
                Toggle(isOn: $settings.settings.discordActivity.enable) {
                    GameSettingLabel("Share activity on Discord", key: "discordActivity.enable", owner: .integrations)
                }.disabled(hasRuntime == false)
                DisclosureGroup("Activity details") {
                    TextField("Application ID", text: $settings.settings.discordActivity.applicationID)
                    TextField("Details", text: $settings.settings.discordActivity.details)
                    TextField("State", text: $settings.settings.discordActivity.state)
                    TextField("Image", text: $settings.settings.discordActivity.image)
                    Button("Clear activity details") { settings.settings.discordActivity = DiscordActivity() }
                    GameSettingBadge("discordActivity", owner: .integrations)
                }.disabled(hasRuntime == false)
            }
            Section("Startup") {
                Toggle(isOn: $settings.settings.rootWorkDir) {
                    GameSettingLabel("Use app folder as working directory", key: "rootWorkDir", owner: .engine)
                }.help("settings.toggle.rootWorkDir.help").disabled(hasRuntime == false)
                Toggle(isOn: $settings.settings.ignoreUnityKeyboardInitializationError) {
                    GameSettingLabel("Ignore Unity keyboard initialization error", key: "ignoreUnityKeyboardInitializationError", owner: .engine)
                }.help("settings.toggle.ignoreUnityKeyboardInitializationError.help").disabled(hasRuntime == false)
            }
            Section("Custom plugins") {
                CustomDylibView(app: app, showCustomPluginWarning: $showCustomPluginWarning,
                                hasShownCustomPluginWarning: $hasShownCustomPluginWarning,
                                hasRuntime: $hasRuntime, userDylibs: $userDylibs)
                GameSettingBadge(nil, timing: .restart)
            }
            Section("Installed runtime") {
                Button(hasRuntime == true ? "Remove runtime…" : "Install runtime") {
                    if hasRuntime == true { confirmRuntimeRemoval = true }
                    else { changeRuntime(remove: false) }
                }.tint(hasRuntime == true ? .red : .accentColor)
            }
        }.formStyle(.grouped)
        .alert("Category change failed", isPresented: Binding(get: { categoryError != nil }, set: { if !$0 { categoryError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(categoryError ?? "") }
        .confirmationDialog("Remove this game's runtime?", isPresented: $confirmRuntimeRemoval, titleVisibility: .visible) {
            Button("Remove runtime", role: .destructive) { changeRuntime(remove: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Wrapper controls and display features will be unavailable. Game data is kept.") }
        .onChange(of: app.info.applicationCategoryType) { applicationCategoryType = app.info.applicationCategoryType }
    }

    private func changeRuntime(remove: Bool) {
        task = .mulgKit
        Task {
            defer { task = .none }
            if remove {
                await GameRuntime.removeFromApp(app.executable)
                if app.hasRuntime() { categoryError = "The runtime could not be removed. Check the log for details." }
            } else {
                do { try await GameRuntime.installInIPA(app.executable) }
                catch { categoryError = error.localizedDescription }
            }
            AppsVM.shared.filteredApps = []
            AppsVM.shared.fetchApps()
        }
    }

    private func changeCategory(_ category: LSApplicationCategoryType) {
        guard task == .none else { return }
        applicationCategoryType = category
        task = .applicationCategoryType
        Task {
            defer { task = .none }
            do { try await Task.detached { try app.setApplicationCategoryType(category) }.value }
            catch { categoryError = error.localizedDescription }
            applicationCategoryType = app.info.applicationCategoryType
        }
    }

}

struct CustomDylibView: View {
    var app: MulgGame
    @Binding var showCustomPluginWarning: Bool
    @Binding var hasShownCustomPluginWarning: Bool
    @Binding var hasRuntime: Bool?
    @Binding var userDylibs: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("settings.customPlugins.title")
                    .font(.headline)
                Spacer()
                Button {
                    if hasShownCustomPluginWarning {
                        selectAndAddDylib()
                    } else {
                        showCustomPluginWarning = true
                    }
                } label: {
                    Label("settings.customPlugins.add", systemImage: "plus")
                }
            }
            if userDylibs.isEmpty {
                Text("settings.customPlugins.empty")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                ForEach(userDylibs, id: \.self) { dylib in
                    HStack {
                        Text(dylib.lastPathComponent)
                        Spacer()
                        Button {
                            removeDylib(dylib)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .disabled(!(hasRuntime ?? true))
        .onAppear {
            reloadUserDylibs()
        }
        .alert("settings.customPlugins.warningTitle", isPresented: $showCustomPluginWarning) {
            Button("button.Cancel", role: .cancel) {}
            Button("settings.customPlugins.warningConfirm", role: .destructive) {
                hasShownCustomPluginWarning = true
                selectAndAddDylib()
            }
        } message: {
            Text("settings.customPlugins.warningMessage")
        }
    }
    private func reloadUserDylibs() {
        userDylibs = GameRuntime.userDylibs(bundleIdentifier: app.info.bundleIdentifier)
    }

    private func selectAndAddDylib() {
        NSOpenPanel.selectDylib { result in
            guard case .success(let url) = result else { return }
            Task(priority: .userInitiated) {
                do {
                    try GameRuntime.addUserDylib(at: url,
                                               bundleIdentifier: app.info.bundleIdentifier,
                                               appExecutable: app.executable)
                } catch {
                    Log.shared.error(error)
                }
                Task { @MainActor in
                    reloadUserDylibs()
                }
            }
        }
    }

    private func removeDylib(_ url: URL) {
        Task(priority: .userInitiated) {
            do {
                try GameRuntime.removeUserDylib(named: url.lastPathComponent,
                                              bundleIdentifier: app.info.bundleIdentifier,
                                              appExecutable: app.executable)
            } catch {
                Log.shared.error(error)
            }
            Task { @MainActor in
                reloadUserDylibs()
            }
        }
    }

}

struct InfoView: View {
    @State var info: AppInfo
    @State var hasRuntime: Bool

    var body: some View {
        List {
            HStack {
                Text("settings.info.displayName")
                Spacer()
                Text("\(info.displayName)")
            }
            HStack {
                Text("settings.info.bundleName")
                Spacer()
                Text("\(info.bundleName)")
            }
            HStack {
                Text("settings.info.bundleIdentifier")
                Spacer()
                Text("\(info.bundleIdentifier)")
            }
            HStack {
                Text("settings.info.bundleVersion")
                Spacer()
                Text("\(info.bundleVersion)")
            }
            HStack {
                Text("settings.applicationCategoryType") + Text(":")
                Spacer()
                Text("\(info.applicationCategoryType.rawValue)")
            }
            HStack {
                Text("settings.info.executableName")
                Spacer()
                Text("\(info.executableName)")
            }
            HStack {
                Text("settings.info.minimumOSVersion")
                Spacer()
                Text("\(info.minimumOSVersion)")
            }
            HStack {
                Text("settings.info.mulgKit")
                Spacer()
                Text(hasRuntime ? "button.Yes" : "button.No")
            }
            HStack {
                Text("settings.info.url")
                Spacer()
                Text("\(info.url.relativePath)")
            }
            HStack {
                Text("settings.info.alias")
                Spacer()
                Text("\(MulgGame.aliasDirectory.appendingPathComponent(info.bundleIdentifier))")
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .padding()
    }
}

struct AsyncToggleStyle: ToggleStyle {
    @Binding var task: BlockingTask

    var role: BlockingTask

    func makeBody(configuration: Configuration) -> some View {
        if task == role {
            return AnyView(
                HStack(spacing: 3) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)

                    configuration.label
                }
            )
        } else {
            return AnyView(
                Toggle(isOn: configuration.$isOn) { configuration.label }
            )
        }
    }
}

extension ToggleStyle where Self == AsyncToggleStyle {
    static func async(_ task: Binding<BlockingTask>, role: BlockingTask) -> AsyncToggleStyle {
        AsyncToggleStyle(task: task, role: role)
    }
}

/// Opt-in scene scaling; its switch can restore the previous renderer policy.
private struct NativeSceneResolutionToggle: View {
    let bundleIdentifier: String
    @State private var enabled = false
    @State private var saveError: String?

    var body: some View {
        Toggle(isOn: Binding(get: { enabled }, set: { value in
            do {
                try GameActions().setUsesNativeSceneResolution(value, for: bundleIdentifier)
                enabled = value
            } catch {
                saveError = String(describing: error)
            }
        })) {
            GameSettingLabel("Native scene resolution", key: "mulg.graphics.nativeSceneResolution", timing: .live, owner: .graphics)
        }
        .toggleStyle(.switch)
        .help("Experimental. Ask a supported game engine to match the 3D scene to the selected output. Requires Force this resolution and pauses while Mulg MetalFX is active. Some games apply or restore the change at their next graphics refresh.")
        .onChange(of: bundleIdentifier, initial: true) { enabled = GameActions().usesNativeSceneResolution(bundleIdentifier) }
        .alert("Couldn't save native scene resolution", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(saveError ?? "") }
    }
}

/// Retina on/off (display.retina), stored through GameActions like the forced resolution.
private struct RetinaToggle: View {
    let bundleIdentifier: String
    @Binding var retina: Bool
    @State private var saveError: String?

    var body: some View {
        Toggle(isOn: Binding(get: { retina }, set: { value in
            do {
                try GameActions().setUsesRetina(value, for: bundleIdentifier)
                retina = value
            } catch {
                saveError = String(describing: error)
            }
        })) {
            GameSettingLabel("Retina mode", key: "mulg.display.retina", timing: .restart, owner: .display)
        }
        .toggleStyle(.switch)
        .help("On: use the selected display's pixel density. Off: use one pixel per point. Restart the game for this change to take effect.")
        .onAppear { retina = GameActions().usesRetina(bundleIdentifier) }
        .alert("Couldn't save Retina mode", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(saveError ?? "") }
    }
}
