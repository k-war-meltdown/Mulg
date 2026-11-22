import Foundation
import Testing
import MulgContracts
@testable import MulgEngine

private struct Ping: EngineEvent { let value: Int }
private struct Pong: EngineEvent {}

@Suite("NoticeCenter") @MainActor
struct NoticeCenterTests {
    @Test("Queued notices respect fullscreen hiding when the presenter attaches")
    func queuedNotice() {
        let center = NoticeCenter()
        center.show(Notice("queued"))
        let presenter = LogNoticePresenter()
        center.hideWhile = { true }
        center.attach(presenter)
        #expect(presenter.shown.isEmpty)
        center.hideWhile = { false }
        center.show(Notice("visible"))
        #expect(presenter.shown.map(\.title) == ["visible"])
    }
}

@Suite("EventBus") @MainActor
struct EventBusTests {
    @Test("Cancellation during delivery skips a later handler in the current snapshot")
    func cancellationDuringDelivery() {
        let bus = EventBus()
        var received: [Int] = []
        var later: EventSubscription?
        bus.subscribe(Ping.self) { _ in received.append(1); later?.cancel() }
        later = bus.subscribe(Ping.self) { _ in received.append(2) }
        bus.publish(Ping(value: 0))
        #expect(received == [1])
    }

    @Test("Nested events finish the older delivery before reaching subscribers")
    func nestedEventsAreOrdered() {
        let bus = EventBus()
        var received: [Int] = []
        bus.subscribe(Ping.self) { event in
            received.append(event.value)
            if event.value == 1 { bus.publish(Ping(value: 2)) }
        }
        bus.subscribe(Ping.self) { received.append($0.value * 10) }
        bus.publish(Ping(value: 1))
        #expect(received == [1, 10, 2, 20])
    }

    @Test("Queued snapshots respect cancellation and only include subscriptions present when published")
    func queuedSnapshotMembership() {
        let bus = EventBus()
        var received: [Int] = []
        var later: EventSubscription?
        bus.subscribe(Ping.self) { event in
            received.append(event.value)
            if event.value == 1 {
                bus.publish(Ping(value: 2))
                later?.cancel()
                bus.subscribe(Ping.self) { received.append($0.value * 100) }
                bus.publish(Ping(value: 3))
            }
        }
        later = bus.subscribe(Ping.self) { received.append($0.value * 10) }
        bus.publish(Ping(value: 1))
        #expect(received == [1, 2, 3, 300])
        #expect(bus.subscriberCount(for: Ping.self) == 2)
    }

    @Test("Self-cancellation excludes queued events and a dropped token does not cancel a handler")
    func selfCancellationAndDroppedToken() {
        let bus = EventBus()
        var received: [Int] = []
        var first: EventSubscription?
        first = bus.subscribe(Ping.self) { event in
            received.append(event.value)
            bus.publish(Ping(value: 2))
            first?.cancel()
        }
        bus.subscribe(Ping.self) { received.append($0.value * 10) }
        bus.publish(Ping(value: 1))
        first?.cancel()
        #expect(received == [1, 10, 20])
        #expect(bus.subscriberCount(for: Ping.self) == 1)
    }

    @Test("Subscription tokens do not keep the bus or handler captures alive")
    func subscriptionLifetime() {
        final class Capture {}
        var bus: EventBus? = EventBus()
        weak var weakBus = bus
        var capture: Capture? = Capture()
        weak var weakCapture = capture
        let subscription = bus!.subscribe(Ping.self) { [capture = capture!] _ in _ = capture }
        capture = nil
        #expect(weakCapture != nil)
        bus = nil
        #expect(weakBus == nil && weakCapture == nil)
        subscription.cancel()
    }

    @Test("Events reach subscribers of their own type only, in order")
    func delivery() {
        let bus = EventBus()
        var received: [Int] = []
        bus.subscribe(Ping.self) { received.append($0.value) }
        bus.subscribe(Ping.self) { received.append($0.value * 10) }
        bus.subscribe(Pong.self) { _ in received.append(-1) }
        bus.publish(Ping(value: 2))
        #expect(received == [2, 20])
    }

    @Test("A cancelled subscription gets nothing")
    func cancel() {
        let bus = EventBus()
        var count = 0
        let subscription = bus.subscribe(Ping.self) { _ in count += 1 }
        subscription.cancel()
        bus.publish(Ping(value: 1))
        #expect(count == 0)
        #expect(bus.subscriberCount(for: Ping.self) == 0)
    }
}

@Suite("HotkeyCenter") @MainActor
struct HotkeyCenterTests {
    @Test("A shortcut's repeats remain consumed after its modifiers or registration are gone")
    func repeatsAfterModifiersReleased() throws {
        let center = HotkeyCenter()
        let hotkey = try #require(Hotkey("option+command+U"))
        var runs = 0
        try center.register(hotkey, owner: .graphics, title: "MetalFX") { runs += 1 }
        #expect(center.handle(keyCode: hotkey.keyCode, modifiers: [.option, .command], isDown: true, isRepeat: false))
        #expect(center.handle(keyCode: hotkey.keyCode, modifiers: [], isDown: true, isRepeat: true))
        center.unregister(hotkey)
        #expect(center.handle(keyCode: hotkey.keyCode, modifiers: [], isDown: true, isRepeat: true))
        #expect(center.handle(keyCode: hotkey.keyCode, modifiers: [], isDown: false, isRepeat: false))
        #expect(runs == 1)
        #expect(!center.handle(keyCode: hotkey.keyCode, modifiers: [], isDown: true, isRepeat: false))
        #expect(!center.handle(keyCode: hotkey.keyCode, modifiers: [], isDown: false, isRepeat: false))
    }

    @Test("⌥⌘U runs its action once and hides press, repeat and release from the game")
    func swallowsWholeKeystroke() throws {
        let center = HotkeyCenter()
        var runs = 0
        let hotkey = try #require(Hotkey("option+command+U"))
        try center.register(hotkey, owner: .graphics, title: "MetalFX") { runs += 1 }

        #expect(center.handle(keyCode: hotkey.keyCode, modifiers: [.option, .command], isDown: true, isRepeat: false))
        #expect(center.handle(keyCode: hotkey.keyCode, modifiers: [.option, .command], isDown: true, isRepeat: true))
        // The modifiers were released first: the key release must still be swallowed.
        #expect(center.handle(keyCode: hotkey.keyCode, modifiers: [], isDown: false, isRepeat: false))
        #expect(runs == 1)
    }

    @Test("The same key without the modifiers goes to the game")
    func plainKeyPassesThrough() throws {
        let center = HotkeyCenter()
        let hotkey = try #require(Hotkey("option+command+U"))
        try center.register(hotkey, owner: .graphics, title: "MetalFX") {}
        #expect(!center.handle(keyCode: hotkey.keyCode, modifiers: [], isDown: true, isRepeat: false))
        #expect(!center.handle(keyCode: hotkey.keyCode, modifiers: [], isDown: false, isRepeat: false))
    }

    @Test("A lost hotkey release does not swallow the next plain release")
    func lostReleaseDoesNotStickKey() throws {
        let center = HotkeyCenter()
        let hotkey = try #require(Hotkey("option+command+U"))
        try center.register(hotkey, owner: .graphics, title: "MetalFX") {}
        #expect(center.handle(keyCode: hotkey.keyCode, modifiers: [.option, .command], isDown: true, isRepeat: false))
        #expect(!center.handle(keyCode: hotkey.keyCode, modifiers: [], isDown: true, isRepeat: false))
        #expect(!center.handle(keyCode: hotkey.keyCode, modifiers: [], isDown: false, isRepeat: false))
    }

    @Test("Two modules cannot take the same hotkey")
    func conflict() throws {
        let center = HotkeyCenter()
        let hotkey = try #require(Hotkey("option+command+P"))
        try center.register(hotkey, owner: .diagnostics, title: "Overlay") {}
        #expect(throws: HotkeyCenter.RegistrationError.alreadyTaken(by: .diagnostics)) {
            try center.register(hotkey, owner: .graphics, title: "Other") {}
        }
    }
}

@Suite("Hotkey parsing")
struct HotkeyParsingTests {
    @Test("Settings strings parse into key code and modifiers")
    func parse() throws {
        let hotkey = try #require(Hotkey("option+command+U"))
        #expect(hotkey.keyCode == 0x20)
        #expect(hotkey.modifiers == [.option, .command])
        #expect(hotkey.description == "⌥⌘U")
    }

    @Test("Strings without a key, or with two keys, are rejected")
    func invalid() {
        #expect(Hotkey("option+command") == nil)
        #expect(Hotkey("u+i") == nil)
        #expect(Hotkey("") == nil)
    }

    @Test("AppKit modifier flags convert without AppKit")
    func appKitFlags() {
        let flags: UInt = (1 << 19) | (1 << 20)   // option + command
        #expect(ModifierSet(appKitFlags: flags) == [.option, .command])
    }
}

@Suite("SafeMode")
struct SafeModeTests {
    private func temporaryMarker() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mulg-safe-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("game.launches")
    }

    @Test("Two unfinished launches in a row start the third in safe mode")
    func triggers() {
        let safeMode = SafeMode(marker: temporaryMarker())
        #expect(safeMode.beginLaunch() == .normal)
        #expect(safeMode.beginLaunch() == .normal)
        #expect(safeMode.beginLaunch() == .safe(unfinishedLaunches: 2))
    }

    @Test("A launch that succeeds resets the count")
    func resets() {
        let safeMode = SafeMode(marker: temporaryMarker())
        _ = safeMode.beginLaunch()
        _ = safeMode.beginLaunch()
        safeMode.launchSucceeded()
        #expect(safeMode.beginLaunch() == .normal)
    }

    @Test("A damaged launch count cannot overflow startup")
    func damagedMarker() throws {
        let safeMode = SafeMode(marker: temporaryMarker())
        try FileManager.default.createDirectory(at: safeMode.marker.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try String(Int.max).write(to: safeMode.marker, atomically: true, encoding: .utf8)
        #expect(safeMode.beginLaunch() == .minimal(unfinishedLaunches: Int.max))
        #expect(safeMode.unfinishedLaunches() == Int.max)
        try "-1".write(to: safeMode.marker, atomically: true, encoding: .utf8)
        #expect(safeMode.beginLaunch() == .normal)
        #expect(safeMode.unfinishedLaunches() == 1)
    }
}

@Suite("PluginLoader")
struct PluginLoaderTests {
    private func folderWithPlugin(named name: String, contents: String, card: PluginCard? = nil) throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mulg-plugins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        if let card {
            let cardFile = file.deletingPathExtension().appendingPathExtension("module.json")
            try JSONEncoder().encode(card).write(to: cardFile)
        }
        return (folder, file)
    }

    @Test("Unknown plugins are skipped unless the user allowed unverified plugins")
    func untrusted() throws {
        let (folder, file) = try folderWithPlugin(named: "extra.dylib", contents: "x")
        var engine = EngineSettings()
        #expect(PluginLoader(folder: folder, engine: engine, safeMode: false).decide(for: file) == .skipUntrusted)
        engine.allowUnverifiedPlugins = true
        #expect(PluginLoader(folder: folder, engine: engine, safeMode: false).decide(for: file) == .load)
    }

    @Test("A plugin whose file changed since install is not loaded")
    func hashMismatch() throws {
        let (folder, file) = try folderWithPlugin(named: "extra.dylib", contents: "changed")
        var engine = EngineSettings()
        engine.trustedPluginHashes["extra.dylib"] = String(repeating: "0", count: 64)
        #expect(PluginLoader(folder: folder, engine: engine, safeMode: false).decide(for: file) == .skipHashMismatch)
    }

    @Test("A trusted plugin with the right hash loads")
    func trusted() throws {
        let (folder, file) = try folderWithPlugin(named: "extra.dylib", contents: "same")
        var engine = EngineSettings()
        let hash: String = try #require(PluginLoader.sha256(of: file))
        engine.trustedPluginHashes["extra.dylib"] = hash
        engine.trustedPluginHashes["extra.module.json"] = "absent"
        #expect(PluginLoader(folder: folder, engine: engine, safeMode: false).decide(for: file) == .load)
    }

    @Test("AppleDouble and other hidden files are never plugins")
    func hiddenFiles() throws {
        let (folder, file) = try folderWithPlugin(named: "real.dylib", contents: "code")
        let appleDouble = folder.appendingPathComponent("._real.dylib")
        try Data("resource fork".utf8).write(to: appleDouble)
        let loader = PluginLoader(folder: folder, engine: EngineSettings(), safeMode: false)
        #expect(loader.pluginFiles().map(\.lastPathComponent) == [file.lastPathComponent])
    }

    @Test("Plugins must be ordinary files even when unverified plugins are allowed")
    func symlink() throws {
        let (folder, file) = try folderWithPlugin(named: "original.dylib", contents: "same")
        let link = folder.appendingPathComponent("linked.dylib")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        var engine = EngineSettings()
        engine.allowUnverifiedPlugins = true
        let loader = PluginLoader(folder: folder, engine: engine, safeMode: false)
        #expect(loader.pluginFiles().contains(link))
        #expect(loader.decide(for: link) == .skipInvalidFile)
    }

    @Test("A damaged plugin card cannot bypass compatibility checks")
    func invalidCard() throws {
        let (folder, file) = try folderWithPlugin(named: "extra.dylib", contents: "same")
        let card = file.deletingPathExtension().appendingPathExtension("module.json")
        try Data("invalid".utf8).write(to: card)
        var engine = EngineSettings()
        engine.trustedPluginHashes["extra.dylib"] = try #require(PluginLoader.sha256(of: file))
        engine.trustedPluginHashes["extra.module.json"] = try #require(PluginLoader.sha256(of: card))
        #expect(PluginLoader(folder: folder, engine: engine, safeMode: false).decide(for: file) == .skipInvalidCard)
    }

    @Test("Cards decide compatibility, the per-game switch and safe mode")
    func cards() throws {
        let card = PluginCard(id: "graphics-metalfx", runtimeProtocol: MulgVersion.runtimeProtocol, experimental: true)
        let (folder, file) = try folderWithPlugin(named: "metalfx.dylib", contents: "m", card: card)
        var engine = EngineSettings()
        engine.allowUnverifiedPlugins = true
        #expect(PluginLoader(folder: folder, engine: engine, safeMode: true).decide(for: file) == .skipSafeMode)
        engine.disabledModules = ["graphics-metalfx"]
        #expect(PluginLoader(folder: folder, engine: engine, safeMode: false).decide(for: file) == .skipSwitchedOff)

        let old = PluginCard(id: "old", runtimeProtocol: MulgVersion.runtimeProtocol + 1, experimental: false)
        let (folder2, file2) = try folderWithPlugin(named: "old.dylib", contents: "o", card: old)
        #expect(PluginLoader(folder: folder2, engine: engine, safeMode: false).decide(for: file2)
            == .skipIncompatible(pluginProtocol: MulgVersion.runtimeProtocol + 1))
    }
}

@MainActor
private final class RecordingModule: GameModule {
    let id: ModuleID
    let isExperimental: Bool
    let log: (String) -> Void
    init(_ id: ModuleID, experimental: Bool = false, log: @escaping (String) -> Void) {
        self.id = id
        self.isExperimental = experimental
        self.log = log
    }
    func prepare(_ context: ModuleContext) throws { log("prepare \(id.rawValue)") }
    func activate(_ context: ModuleContext) { log("activate \(id.rawValue)") }
}

@Suite("ModuleHost") @MainActor
struct ModuleHostTests {
    @Test func startupAvailabilityIsWrittenEvenWithDiagnosticsDisabled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root), id = "test.module-status"
        var settings = GameSettings(bundleIdentifier: id)
        settings.mulg.engine.disabledModules = ["diagnostics"]
        let context = ModuleContext(bundleIdentifier: id, paths: paths, settingsStore: SettingsStore(paths: paths),
                                    settings: settings, launch: .safe(unfinishedLaunches: 2), bridge: nil)
        let host = ModuleHost(context: context, modules: [RecordingModule(.engine) { _ in },
            RecordingModule(.graphics, experimental: true) { _ in }, RecordingModule(.diagnostics) { _ in }])
        host.prepareAll()
        host.activateAll()
        ReportWriter.shared.flush()
        let file = paths.diagnosticsDirectory(for: id).appendingPathComponent("startup.json")
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(report["processIdentifier"] as? Int32 == ProcessInfo.processInfo.processIdentifier)
        #expect(report["safeMode"] as? Bool == true)
        let modules = try #require(report["modules"] as? [[String: Any]])
        #expect(modules.first { $0["id"] as? String == "graphics" }?["state"] as? String == "offInSafeMode")
        #expect(modules.first { $0["id"] as? String == "diagnostics" }?["state"] as? String == "switchedOff")
    }

    private func context(settings: GameSettings = GameSettings(), launch: SafeMode.Launch = .normal) -> ModuleContext {
        let paths = ContainerPaths(home: FileManager.default.temporaryDirectory)
        return ModuleContext(bundleIdentifier: "test", paths: paths, settingsStore: SettingsStore(paths: paths),
                             settings: settings, launch: launch, bridge: nil)
    }

    @Test("Modules start in the fixed order, identity before display, whatever order they are given in")
    func order() {
        var log: [String] = []
        let host = ModuleHost(context: context(), modules: [
            RecordingModule(.engine) { log.append($0) },
            RecordingModule(.controls) { log.append($0) },
            RecordingModule(.display) { log.append($0) },
            RecordingModule(.identity) { log.append($0) }
        ])
        host.prepareAll()
        host.activateAll()
        host.activateAll()
        #expect(log == ["prepare engine", "prepare identity", "prepare display", "prepare controls",
                        "activate engine", "activate identity", "activate display", "activate controls"])
    }

    @Test("Switched-off modules don't start; essential modules can't be switched off")
    func switchedOff() {
        var settings = GameSettings()
        settings.mulg.engine.disabledModules = ["display", "engine"]
        var log: [String] = []
        let host = ModuleHost(context: context(settings: settings), modules: [
            RecordingModule(.display) { log.append($0) },
            RecordingModule(.engine) { log.append($0) }
        ])
        host.prepareAll()
        #expect(log == ["prepare engine"])
        #expect(host.reports[.display]?.state == .switchedOff)
    }

    @Test("Safe mode switches experimental modules off and reports them")
    func safeMode() {
        var log: [String] = []
        let host = ModuleHost(context: context(launch: .safe(unfinishedLaunches: 2)), modules: [
            RecordingModule(.engine) { log.append($0) },
            RecordingModule(.graphics, experimental: true) { log.append($0) },
            RecordingModule(.identity) { log.append($0) }
        ])
        host.prepareAll()
        #expect(log == ["prepare engine", "prepare identity"])
        #expect(host.modulesOffInSafeMode == [.graphics])
    }
}

@Suite("Local runtime settings") @MainActor
struct LocalSettingsTests {
    @Test("Local changes notify modules once; unchanged updates and reloads do not")
    func notifications() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = ContainerPaths(home: home)
        let context = ModuleContext(bundleIdentifier: "test", paths: paths, settingsStore: SettingsStore(paths: paths),
                                    settings: GameSettings(bundleIdentifier: "test"), launch: .normal, bridge: nil)
        var changes: [SettingsChanged] = []
        context.events.subscribe(SettingsChanged.self) { changes.append($0) }
        let before = context.settings.mulg.graphics.metalFX.enabled
        context.updateSettings { $0.mulg.graphics.metalFX.enabled.toggle() }
        #expect(changes.count == 1)
        #expect(changes.first?.old.mulg.graphics.metalFX.enabled == before)
        #expect(changes.first?.new.mulg.graphics.metalFX.enabled == !before)
        context.updateSettings { _ in }
        #expect(!context.reloadSettings())
        #expect(changes.count == 1)
    }
}

@Suite("Runtime version")
struct VersionTests {
    @Test("Games injected by upstream or another protocol version are asked to re-inject")
    func compatibility() {
        var engine = EngineSettings()
        #expect(MulgVersion.compatibility(of: engine) == .reinjectNeeded(injectedVersion: nil))
        engine.injectedRuntimeProtocol = MulgVersion.runtimeProtocol
        #expect(MulgVersion.compatibility(of: engine) == .compatible)
        engine.injectedRuntimeProtocol = MulgVersion.runtimeProtocol + 1
        engine.injectedRuntimeVersion = "9.9"
        #expect(MulgVersion.compatibility(of: engine) == .reinjectNeeded(injectedVersion: "9.9"))
    }
}

@Suite("Read-ahead budget")
struct ReadAheadBudgetTests {
    @Test("Speculative and purgeable subsets are not counted a second time")
    func disjointPages() {
        var vm = vm_statistics64()
        vm.free_count = 100; vm.inactive_count = 200
        vm.speculative_count = 80; vm.purgeable_count = 150
        #expect(EngineCoreModule.reclaimablePageCount(vm) == 300)
    }

    @Test("Repeated headroom queries release their host-port send references")
    func hostPortReferences() throws {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var before: mach_port_urefs_t = 0, after: mach_port_urefs_t = 0
        try #require(mach_port_get_refs(mach_task_self_, host, MACH_PORT_RIGHT_SEND, &before) == KERN_SUCCESS)
        for _ in 0..<20 { _ = EngineCoreModule.reclaimableMemory() }
        try #require(mach_port_get_refs(mach_task_self_, host, MACH_PORT_RIGHT_SEND, &after) == KERN_SUCCESS)
        #expect(after == before)
    }

    @Test("Bounded by 2 GB, an eighth of memory and a quarter of what macOS can hand out")
    func budget() {
        let gb = Int64(1) << 30
        #expect(EngineCoreModule.readAheadBudget(physical: 64 * gb, reclaimable: 40 * gb) == 2 * gb)
        #expect(EngineCoreModule.readAheadBudget(physical: 8 * gb, reclaimable: 40 * gb) == gb)
        #expect(EngineCoreModule.readAheadBudget(physical: 64 * gb, reclaimable: 2 * gb) == gb / 2)
        #expect(EngineCoreModule.readAheadBudget(physical: 8 * gb, reclaimable: nil) == gb)
        #expect(EngineCoreModule.reclaimableMemory().map { $0 > 0 } == true)
    }
}

@Suite("Engine environment") @MainActor
struct EngineEnvironmentTests {
    @Test("Valid values apply; invalid values cannot truncate or replace them")
    func validated() {
        let name = "MULG_ENGINE_TEST_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        defer { unsetenv(name) }
        var settings = GameSettings()
        settings.mulg.engine.environment[name] = "valid"
        EngineCoreModule.applyEnvironment(settings)
        #expect(getenv(name).map { String(cString: $0) } == "valid")
        settings.mulg.engine.environment[name] = "truncated\0value"
        EngineCoreModule.applyEnvironment(settings)
        #expect(getenv(name).map { String(cString: $0) } == "valid")
    }
}

@Suite("LifecycleState") @MainActor
struct LifecycleStateTests {
    @Test("Window state maps onto iOS states; each transition is sent once, in iOS order")
    func steps() {
        #expect(LifecycleState(focused: true, onScreen: true) == .active)
        #expect(LifecycleState(focused: false, onScreen: true) == .inactive)
        #expect(LifecycleState(focused: true, onScreen: false) == .background)
        #expect(LifecycleState.active.steps(to: .background) == [.resignActive, .enterBackground])
        #expect(LifecycleState.background.steps(to: .active) == [.enterForeground, .becomeActive])
        #expect(LifecycleState.inactive.steps(to: .active) == [.becomeActive])
        #expect(LifecycleState.background.steps(to: .background).isEmpty)
    }

    @Test("Unfocused, Mulg never brings a game UIKit backgrounded forward; focus still does")
    func unfocusedNeverMovesUp() {
        // Another Space: UIKit backgrounded the game; a delayed "inactive" must not send willEnterForeground.
        #expect(LifecycleState.unfocusedTarget(.inactive, current: .background) == .background)
        #expect(LifecycleState.unfocusedTarget(.inactive, current: .active) == .inactive)
        #expect(LifecycleState.unfocusedTarget(.background, current: .active) == .background)
        // Focused again: all the way to active, whatever UIKit did.
        #expect(LifecycleState.unfocusedTarget(.active, current: .background) == .active)
    }
}

@Suite("Settings watch")
struct SettingsFingerprintTests {
    @Test("Watching settings catches changes saved before scene activation")
    @MainActor
    func settingsChangedBeforeWatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root), id = "test.watch-startup"
        let store = SettingsStore(paths: paths)
        let initial = GameSettings(bundleIdentifier: id)
        let context = ModuleContext(bundleIdentifier: id, paths: paths, settingsStore: store,
                                    settings: initial, launch: .normal, bridge: nil)
        var saved = initial
        saved.mulg.engine.keepRunningUnfocused.toggle()
        try store.save(saved)
        let engine = EngineCoreModule(bundleURL: root)
        engine.watchSettings(context)
        #expect(context.settings.mulg.engine.keepRunningUnfocused == saved.mulg.engine.keepRunningUnfocused)
    }

    @Test("Another game's save leaves this game's fingerprint alone; an atomic save of its own changes it")
    func fingerprintFollowsOwnFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let own = folder.appendingPathComponent("own.plist"), other = folder.appendingPathComponent("other.plist")
        try Data("a".utf8).write(to: own, options: .atomic)
        let first = EngineCoreModule.fingerprint(of: own)
        #expect(first != nil)
        try Data("b".utf8).write(to: other, options: .atomic)
        #expect(EngineCoreModule.fingerprint(of: own) == first)
        try Data("a".utf8).write(to: own, options: .atomic)
        #expect(EngineCoreModule.fingerprint(of: own) != first)
        #expect(EngineCoreModule.fingerprint(of: folder.appendingPathComponent("missing.plist")) == nil)
    }
}

@Suite("Game data folders at start")
struct GameDataBootstrapTests {
    /// A minimal game bundle whose Info.plist points at `dataRoot`.
    private func gameBundle(in folder: URL, id: String, dataRoot: String) throws -> Bundle {
        let app = folder.appendingPathComponent("Game.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "MulgGameDataRoot": dataRoot]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        return try #require(Bundle(url: app))
    }

    @Test("A root that is not a game-data folder fails at once; a missing owner record says so after retrying")
    func storageFailuresNameTheirStep() throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("mulg-bootstrap-" + UUID().uuidString)
        defer { try? files.removeItem(at: folder) }
        let wrong = try gameBundle(in: folder.appendingPathComponent("a"), id: "test.game", dataRoot: "/tmp/elsewhere")
        let started = Date()
        #expect(throws: GameDataBootstrap.Failure.self) { try GameDataBootstrap.prepare(bundle: wrong) }
        #expect(Date().timeIntervalSince(started) < 1)
        let root = folder.appendingPathComponent("Support/test.game").path
        let missing = try gameBundle(in: folder.appendingPathComponent("b"), id: "test.game", dataRoot: root)
        do {
            try GameDataBootstrap.prepare(bundle: missing)
            Issue.record("a missing owner record must fail")
        } catch GameDataBootstrap.Failure.unavailable(let reason) {
            #expect(reason.contains("owner record unreadable"))
            #expect(reason.contains("No such file"))
        }
    }

    @Test("Native framework downloads use the external game files without replacing existing data")
    func linksStandardNativeFolders() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("mulg-native-folders-" + UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let local = root.appendingPathComponent("Container/Data"), external = root.appendingPathComponent("Game/Data")
        try files.createDirectory(at: local.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        #expect(Set(GameDataBootstrap.linkStandardFolders(local: local, external: external)) == ["Documents", "SystemData", "tmp"])
        try Data("SDK download".utf8).write(to: local.appendingPathComponent("Documents/pack"))
        #expect(try Data(contentsOf: external.appendingPathComponent("Documents/pack")) == Data("SDK download".utf8))
        #expect(GameDataBootstrap.linkStandardFolders(local: local, external: external).isEmpty)
        try files.removeItem(at: local.appendingPathComponent("Documents"))
        try files.createDirectory(at: local.appendingPathComponent("Documents"), withIntermediateDirectories: false)
        try Data("local save".utf8).write(to: local.appendingPathComponent("Documents/save"))
        #expect(GameDataBootstrap.linkStandardFolders(local: local, external: external).isEmpty)
        #expect(try Data(contentsOf: local.appendingPathComponent("Documents/save")) == Data("local save".utf8))
        #expect(try Data(contentsOf: external.appendingPathComponent("Documents/pack")) == Data("SDK download".utf8))
    }

    @Test("Empty and missing download folders become links to the game folder; files and macOS folders stay")
    func linksEmptyLibraryFolders() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("mulg-bootstrap-" + UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let local = root.appendingPathComponent("Container/Library"), external = root.appendingPathComponent("Game/Library")
        for name in ["Preferences", "Caches", "SDKCache", "Busy"] {
            try files.createDirectory(at: local.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: local.appendingPathComponent("Busy/file"))
        let linked = GameDataBootstrap.linkLibraryFolders(local: local, external: external)
        // Caches (empty), SDKCache (empty) and Application Support (missing) now point at the game folder.
        #expect(Set(linked) == ["Caches", "SDKCache", "Application Support"])
        for name in linked {
            #expect(try files.destinationOfSymbolicLink(atPath: local.appendingPathComponent(name).path)
                    == external.appendingPathComponent(name).path)
        }
        try Data("download".utf8).write(to: local.appendingPathComponent("Caches/pack"))
        #expect(files.fileExists(atPath: external.appendingPathComponent("Caches/pack").path))
        // A folder with files is the app's to move; Preferences belongs to macOS.
        for name in ["Busy", "Preferences"] {
            #expect((try local.appendingPathComponent(name).resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true)
        }
        #expect(GameDataBootstrap.linkLibraryFolders(local: local, external: external).isEmpty)  // nothing twice
    }
}
