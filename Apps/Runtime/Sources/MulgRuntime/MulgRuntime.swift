import Foundation
import Darwin
import MulgBridge
import MulgContracts
import MulgDiagnostics
import MulgEngine
import MulgIdentity
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// The runtime injected into each game: assembles the game-side modules and starts them.
///
/// This is the only code that knows every module; the modules themselves only know the
/// engine, contracts and bridge (PLAN.md §1.5 rule 2).
@MainActor
public final class MulgRuntime {
    public static let shared = MulgRuntime()

    public private(set) var host: ModuleHost?
    /// Scene activation, and app activation for games on the older app-delegate lifecycle.
    private var activationObservers: [NSObjectProtocol] = []
    private var windowObserver: NSObjectProtocol?
    private var quitObserver: NSObjectProtocol?
    private let logger = MulgLog.logger(.engine)
    private var sessionLease: GameSessionLease?
    /// How long a starting game waits for the app to release it (an install or runtime move under way).
    static let leaseWait: TimeInterval = 30

    /// Every game-side module, in any order; the host sorts them into the start order.
    static func makeModules() -> [any GameModule] {
        RuntimeModules.all()
    }

    func start() {
        guard host == nil else { return }
        let paths = ContainerPaths.current()
        // A usable fallback path does not restore CF's cached main bundle. Continuing
        // with "unknown" loses settings, storage and the bridge, then IOSurface can
        // dereference the missing CF bundle during the first Metal device creation.
        guard let mainBundle = MainGameBundleURL.nativeMainBundle(),
              let bundleIdentifier = mainBundle.bundleIdentifier else {
            let message = "macOS could not initialize the game's main bundle. Mulg stopped before graphics startup. Reopen the game from Mulg after refreshing its signing permissions; check that its app folder is accessible."
            logger.error("\(message, privacy: .public)")
            if let url = MainGameBundleURL.resolve(),
               let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist")),
               let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
               let info = object as? [String: Any],
               let identifier = info["CFBundleIdentifier"] as? String,
               !identifier.isEmpty, !identifier.contains("/"), identifier != ".", identifier != ".." {
                try? RuntimeStartupFailure(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                    bundleIdentifier: identifier, message: message).save(paths: paths)
            }
            // No game session has started. Do not run C++ teardown while dyld is
            // still initializing the game's images; the failure report is already closed.
            _exit(78)
        }
        // Still inside the dyld constructor: a failure records why and ends with _exit, never exit(), which ran
        // C++ teardown of half-initialised images. Both paths used to end the game silently.
        func fail(_ message: String, code: Int32) -> Never {
            logger.error("\(message, privacy: .public)")
            try? RuntimeStartupFailure(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                                       bundleIdentifier: bundleIdentifier, message: message).save(paths: paths)
            _exit(code)
        }
        // The app holds the lease while it installs, re-signs or moves the game to a new runtime (after every
        // update, at app start). A game opened from the Dock then quit at once; it now waits for the lease.
        let token = ProcessInfo.processInfo.environment[GameSessionLease.launchTokenEnvironmentKey]
        let leaseDeadline = Date().addingTimeInterval(Self.leaseWait)
        while sessionLease == nil {
            do {
                sessionLease = try GameSessionLease(bundleIdentifier: bundleIdentifier, paths: paths, launchToken: token)
            } catch GameSessionLease.Failure.busy where Date() < leaseDeadline {
                usleep(250_000)
            } catch {
                fail("Another session or the app (installing or updating this game) still owns it: \(error). Open the game again in a moment.",
                     code: 75)
            }
        }
        unsetenv(GameSessionLease.launchTokenEnvironmentKey)
        do { try GameDataBootstrap.prepare(bundle: mainBundle) }
        catch {
            fail("Game data storage is unavailable: \(error). If the game's data is on an external drive, connect it and open the game again.",
                 code: 74)
        }
        let store = SettingsStore(paths: paths)
        let loaded = store.load(bundleIdentifier: bundleIdentifier)
        var settings = loaded.settings
        // Only a report tied to a module's own code may persistently disable it.
        // The startup journal describes timing, not the crashed thread: an SDK can
        // die while unrelated controls/graphics prepare on the main thread.
        let lastCrash = DiagnosticsModule.lastCrash(settings: settings, paths: paths, bundleIdentifier: bundleIdentifier)
        let safeMode = SafeMode(paths: paths, bundleIdentifier: bundleIdentifier)
        let crashedModule = SafeMode.moduleToDisable(blamedModule: lastCrash?.module, settings: settings)
        if let crashedModule {
            settings.mulg.engine.disabledModules = (settings.mulg.engine.disabledModules + [crashedModule.rawValue]).sorted()
            do {
                // Merged onto the file as it is now: a change the app saved since the load above survives.
                settings = try store.save(settings, basedOn: loaded.settings)
            } catch {
                logger.error("Could not save settings: \(error.description, privacy: .public)")
            }
        }
        let launch = safeMode.beginLaunch(settings: settings)
        DiagnosticsModule.installCrashReporter(settings: settings, paths: paths, bundleIdentifier: bundleIdentifier)
        DiagnosticsModule.startDebugger(settings: settings, paths: paths, bundleIdentifier: bundleIdentifier,
                                        minimalRecovery: launch.isMinimal)
        // Before the first Metal device; recovery gates optional validation without saving preferences.
        EngineCoreModule.applyEnvironment(settings, minimalRecovery: launch.isMinimal)
        DiagnosticsModule.setMetalEnvironment(settings, minimalRecovery: launch.isMinimal)

        let bridge: (any MacBridge)?
        switch BridgeLoader.load(expectedVersion: MulgVersion.current, expectedProtocol: MulgVersion.runtimeProtocol) {
        case .success(let loadedBridge):
            bridge = loadedBridge
        case .failure(let error):
            bridge = nil
            logger.error("Bridge not loaded: \(error.description, privacy: .public)")
        }

        let context = ModuleContext(
            bundleIdentifier: bundleIdentifier,
            paths: paths,
            settingsStore: store,
            settings: settings,
            launch: launch,
            bridge: bridge)
        let host = ModuleHost(context: context, modules: Self.makeModules())
        context.reportLaunchStage = { stage, module in safeMode.stage(stage, module: module) }
        self.host = host
        host.prepareAll()

        showStartupNotices(context: context, host: host, settingsProblem: loaded.problem, bridgeMissing: bridge == nil,
                           crashedModule: crashedModule, crashed: lastCrash != nil, froze: lastCrash?.hang == true)
        loadPlugins(context: context)
        safeMode.stage(.waitingForScene)
        waitForFirstScene(host: host, safeMode: safeMode)
    }

    private func showStartupNotices(context: ModuleContext, host: ModuleHost,
                                    settingsProblem: SettingsStoreError?, bridgeMissing: Bool,
                                    crashedModule: ModuleID?, crashed: Bool, froze: Bool) {
        let event = froze ? "froze" : "crashed"
        if let crashedModule {
            context.notices.show(Notice(
                "Switched off after a \(froze ? "freeze" : "crash"): \(crashedModule.rawValue)",
                lines: ["The last launch \(event) in this module. Switch it back on in the game's Modules settings."],
                style: .warning, duration: .seconds(8)))
        } else if crashed {
            context.notices.show(Notice(
                "The last launch \(event)",
                lines: ["A report was saved. To share it, use Export diagnostics in the game's settings."],
                style: .warning, duration: .seconds(8)))
        }
        if let settingsProblem {
            // Upstream silently fell back to defaults here (PLAN.md §6, §12).
            logger.error("\(settingsProblem.description, privacy: .public)")
            context.notices.show(Notice("Settings could not be read", lines: ["This game is using default settings."], style: .warning))
        }
        if context.launch.isSafe {
            let unfinished: Int
            switch context.launch {
            case .safe(let count), .minimal(let count): unfinished = count
            case .normal: unfinished = 0
            }
            let names = host.modulesOffInSafeMode.map(\.rawValue).joined(separator: ", ")
            context.notices.show(Notice(
                context.launch.isMinimal ? "Minimal recovery mode" : "Safe mode",
                lines: ["The last \(unfinished) launches did not finish.",
                        names.isEmpty ? "No experimental modules were running." : "Features switched off: \(names). Stable presentation remains available."],
                style: .warning, duration: .seconds(8)))
        }
        // An exported game carries MulgRuntime inside and was never injected by an app on this Mac.
        let exported = Bundle.main.privateFrameworksURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("MulgRuntime.framework").path)
        } ?? false
        if !exported, case .reinjectNeeded = MulgVersion.compatibility(of: context.settings.mulg.engine) {
            context.notices.show(Notice(
                "Re-inject this game",
                lines: ["It was set up by a different version of the app. Re-inject it from the app's game settings."],
                style: .warning, duration: .seconds(6)))
        }
        if bridgeMissing {
            context.notices.show(Notice("Mac features unavailable", lines: ["Re-inject the game to restore them."], style: .warning))
        }
    }

    private func loadPlugins(context: ModuleContext) {
        guard let folder = PluginLoader.defaultFolder() else { return }
        let loader = PluginLoader(folder: folder, engine: context.settings.mulg.engine, safeMode: context.launch.isSafe,
                                  minimalRecovery: context.launch.isMinimal)
        for result in loader.loadAll() {
            if let error = result.loadError {
                logger.error("Plugin \(result.fileName, privacy: .public) failed to load: \(error, privacy: .public)")
            } else if result.decision != .load {
                logger.notice("Plugin \(result.fileName, privacy: .public) skipped: \(String(describing: result.decision), privacy: .public)")
                if result.decision == .skipHashMismatch {
                    context.notices.show(Notice("Plugin changed: \(result.fileName)",
                                                lines: ["It was not loaded because it no longer matches the installed copy."],
                                                style: .warning))
                } else if result.decision == .skipInvalidCard {
                    context.notices.show(Notice("Plugin metadata invalid: \(result.fileName)",
                                                lines: ["It was not loaded. Reinstall the plugin to repair its metadata."],
                                                style: .warning))
                } else if result.decision == .skipInvalidFile {
                    context.notices.show(Notice("Plugin file invalid: \(result.fileName)",
                                                lines: ["Only ordinary plugin files can be loaded."],
                                                style: .warning))
                } else if case .skipDependency(let path) = result.decision {
                    context.notices.show(Notice("Plugin dependency unavailable: \(result.fileName)",
                                                lines: ["It was not loaded: \(path)"], style: .warning))
                }
            }
        }
    }

    private func waitForFirstScene(host: ModuleHost, safeMode: SafeMode) {
        #if canImport(UIKit) && !os(watchOS)
        activationObservers = [UIScene.didActivateNotification, UIApplication.didBecomeActiveNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.firstSceneActivated(host: host, safeMode: safeMode)
                }
            }
        }
        #else
        host.activateAll()
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    private func firstSceneActivated(host: ModuleHost, safeMode: SafeMode) {
        // Whichever comes first; scene apps get both.
        guard !activationObservers.isEmpty else { return }
        for observer in activationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        activationObservers = []
        if let window = Self.keyWindow() {
            host.context.notices.attach(ToastPresenter(window: window))
        } else {
            windowObserver = NotificationCenter.default.addObserver(
                forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { [weak self, weak host] notification in
                nonisolated(unsafe) let object = notification.object
                MainActor.assumeIsolated {
                    guard let self, let host, let window = object as? UIWindow else { return }
                    host.context.notices.attach(ToastPresenter(window: window))
                    if let observer = self.windowObserver {
                        NotificationCenter.default.removeObserver(observer)
                        self.windowObserver = nil
                    }
                }
            }
        }
        host.activateAll()
        host.context.menus.install(bridge: host.context.bridge)
        Task { @MainActor in
            try? await Task.sleep(for: SafeMode.successDelay)
            if safeMode.record()?.stage == .running { safeMode.stage(.healthy) }
        }
        // Quitting before then is not a crash either.
        host.context.events.subscribe(GameClosing.self) { _ in safeMode.stage(.closing) }
        host.context.events.subscribe(GameShutdownFinished.self) { _ in
            safeMode.launchSucceeded()
            ReportWriter.shared.flush()
        }
        quitObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            safeMode.launchSucceeded()
            // Reports are written in the background; the last ones must land before exit.
            ReportWriter.shared.flush()
        }
    }

    static func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? UIApplication.shared.delegate?.window ?? nil
    }
    #endif
}

/// Called by the constructor in MulgRuntimeBoot.m, on the main thread, before `main`.
@_cdecl("mulg_runtime_start")
public func mulgRuntimeStart() {
    MainActor.assumeIsolated {
        MulgRuntime.shared.start()
    }
}
