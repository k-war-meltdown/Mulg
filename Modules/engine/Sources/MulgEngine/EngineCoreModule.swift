import Foundation
import Metal
import MulgBridge
import MulgContracts
import MulgEngineHooks
import os
import Synchronization
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// The engine's own start-up work, ported from upstream `Mulg.launch()` and
/// `MulgLoader.m` (PLAN.md §16.2):
/// - the Unreal Engine path fix, now only for Unreal games and built from the real home
///   folder (E2);
/// - the sleep-spam throttle, reading its setting once (E4);
/// - the working directory set to "/" like on iOS;
/// - closing the window sends the game through a normal iOS shutdown (upstream quitWhenClose);
/// - window focus, minimising and hiding the game reach it as the iOS lifecycle, each step once;
/// - Metal compiles the game's shaders on every core it may use (`engine.maximizeShaderCompilation`).
/// - settings changed in the Mulg app while the game runs reach the modules (`SettingsChanged`).
/// - macOS memory pressure reaches the game as the iOS memory warning (`engine.memoryWarnings`);
/// - the game's big asset files are read ahead at launch (`engine.readAhead`).
@MainActor
public final class EngineCoreModule: GameModule {
    public let id = ModuleID.engine
    private let bundleURL: URL?
    private var settingsWatch: (any DispatchSourceFileSystemObject)?
    private var reloadPending = false
    /// This game's settings file as last read (`fingerprint(of:)`).
    private var settingsFingerprint: [Int]?
    private var memoryPressure: (any DispatchSourceMemoryPressure)?
    private var lastMemoryWarning: ContinuousClock.Instant?
    /// True while this module posts its own warning, so its observer does not report it twice.
    private var postingMemoryWarning = false
    /// When each source last published `MemoryPressure` (the dispatch source; Mac Catalyst's warning). One
    /// pressure reported by both is published once, whichever comes first (modules freed their caches twice).
    private var lastPressurePublished: ContinuousClock.Instant?
    private var lastWarningPublished: ContinuousClock.Instant?
    private let readAheadCancelled = Mutex(false)
    private var audioOutput: GameAudioOutput?
    #if targetEnvironment(macCatalyst)
    private var fullscreenSceneObserver: NSObjectProtocol?
    #endif

    public init(bundleURL: URL? = nil) {
        self.bundleURL = bundleURL ?? MainGameBundleURL.resolve()
    }

    /// Unreal Engine games ship one of these files in the app bundle (upstream MulgInfo).
    public static let unrealMarkerFiles = ["ue4commandline.txt", "uecommandline.txt"]

    public static func isUnrealEngine(bundleURL: URL) -> Bool {
        unrealMarkerFiles.contains { name in
            FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(name).path)
        }
    }

    /// Sets the game's `engine.environment` variables. The runtime calls this before any module
    /// prepares, like the HUD switch, because Metal and game engines read theirs once at start-up.
    /// dyld has read its variables before Mulg loads, and would pass `DYLD_` ones on to child
    /// processes, so those are skipped.
    public static func applyEnvironment(_ settings: GameSettings, minimalRecovery: Bool = false) {
        let logger = MulgLog.logger(.engine)
        for (name, value) in settings.mulg.engine.environment.sorted(by: { $0.key < $1.key }) {
            guard EngineSettings.environmentProblem(name: name, value: value) == nil else {
                logger.error("Environment variable '\(name, privacy: .public)' ignored")
                continue
            }
            if minimalRecovery && LaunchEnvironment.managedMetalKeys.contains(name) { continue }
            if setenv(name, value, 1) == 0 {
                logger.info("Environment variable '\(name, privacy: .public)' set")
            } else {
                logger.error("Environment variable '\(name, privacy: .public)' could not be set")
            }
        }
    }

    public func prepare(_ context: ModuleContext) throws {
        guard let bundleURL else {
            throw NSError(domain: "MulgEngine.Bundle", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The installed game bundle could not be located. Reopen it from Mulg after checking its drive and permissions."])
        }
        try? context.hooks.claim("MTLCreateSystemDefaultDevice / MTLCopyAllDevices (native-device discovery)",
                                 owner: id, kind: .interpose)
        #if targetEnvironment(macCatalyst)
        try? context.hooks.claim("os_proc_available_memory (game memory compatibility)",
                                 owner: id, kind: .interpose)
        #endif
        let audio = GameAudioOutput(context: context)
        audioOutput = audio
        audio.start()
        #if canImport(UIKit) && !os(watchOS)
        if mulg_engine_install_lifecycle_notifications() {
            try? context.hooks.claim("NSNotificationCenter.gameLifecycleObservers", owner: id, kind: .swizzle)
        } else {
            context.hooks.recordMissing("NSNotificationCenter.gameLifecycleObservers", owner: id, kind: .swizzle)
            context.logger(for: id).warning("Game lifecycle observer tracking is incomplete; native lifecycle delivery is retained")
        }
        mulg_engine_set_keep_active(context.settings.mulg.engine.keepRunningUnfocused)
        if mulg_engine_install_lifecycle_delegate_hooks() > 0 {
            try? context.hooks.claim("Game lifecycle delegates (keep-running suspend policy)", owner: id, kind: .swizzle)
        }
        let uikit = mulg_engine_install_uikit_hooks { view in
            MainActor.assumeIsolated {
                if let view = view as? UIView { GameViewport.shared.laidOut(view) }
            }
        }
        for (flag, target) in [(MulgEngineUIKitHook.applicationState, "UIApplication.applicationState"),
                                (.sceneState, "UIScene.activationState"), (.viewLayout, "UIView.layoutSubviews")] {
            if uikit.contains(flag) { try? context.hooks.claim(target, owner: id, kind: .swizzle) }
            else { context.hooks.recordMissing(target, owner: id, kind: .swizzle) }
        }
        #endif
        // What the game may use; the rest is answered "denied" before macOS would ask (PrivacySettings).
        Self.applyPrivacy(context.settings.mulg.privacy)
        context.events.subscribe(SettingsChanged.self) { event in
            guard event.old.mulg.privacy != event.new.mulg.privacy else { return }
            Self.applyPrivacy(event.new.mulg.privacy)
        }
        let unreal = Self.isUnrealEngine(bundleURL: bundleURL)
        _ = mulg_engine_install_continued_processing_hooks()
        let compat = mulg_engine_install_compat_hooks(unreal, context.settings.checkMicPermissionSync)
        if compat.contains(.subscription) {
            try? context.hooks.claim("VSSubscriptionRegistrationCenter.setCurrentSubscription:", owner: id,
                                     kind: .swizzle, privateAPI: true)
        }
        if compat.contains(.regex) {
            try? context.hooks.claim("NSString._stringByReplacingOccurrencesOfRegularExpressionPattern:withTemplate:options:range:",
                                     owner: id, kind: .swizzle, privateAPI: true)
        }
        if compat.contains(.microphone) {
            try? context.hooks.claim("AVAudioSession.requestRecordPermission:", owner: id, kind: .swizzle)
        }
        if compat.contains(.privacy) {
            try? context.hooks.claim("PHPhotoLibrary / CLLocationManager authorization (privacy)", owner: id, kind: .swizzle)
        }
        if compat.contains(.missingMicrophone) {
            for target in ["AVAudioSession.recordPermission", "AVAudioApplication.recordPermission",
                           "AVAudioApplication.requestRecordPermissionWithCompletionHandler:",
                           "AVCaptureDevice.authorizationStatusForMediaType:",
                           "AVCaptureDevice.requestAccessForMediaType:completionHandler:"] {
                try? context.hooks.claim(target, owner: id, kind: .swizzle)
            }
            DispatchQueue.main.async {
                if mulg_engine_audio_input_missing() {
                    context.logger(for: .engine).notice("This Mac has no audio input: the game is told microphone access is denied")
                }
            }
        }

        let support = Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "MulgGameDataRoot") as? String
        if unreal || support?.hasPrefix("/") == true {
            // Directory APIs can be appended as relative paths by mobile engines.
            // Every moved-data game needs owned-directory repair; broader legacy
            // doubled-slash correction remains limited to Unreal.
            var roots = [context.paths.home.path, NSHomeDirectory(), bundleURL.path]
            if let support, support.hasPrefix("/") {
                roots.append(URL(fileURLWithPath: support).appendingPathComponent("Data").path)
            }
            mulg_engine_configure_game_path_roots(roots, unreal)
            try? context.hooks.claim("open/stat/lstat/access/rename/unlink/mkdir/rmdir/opendir/fopen (game path repair)", owner: id, kind: .interpose)
            context.logger(for: id).info("Game path repair on (legacy Unreal: \(unreal, privacy: .public))")
        } else {
            mulg_engine_configure_unreal_path_fix(nil)
        }

        let throttle = context.settings.blockSleepSpamming
        mulg_engine_configure_sleep_throttle(throttle, 100_000)
        if throttle {
            try? context.hooks.claim("usleep", owner: id, kind: .interpose)
        }

        // Interposed at load time; only threads named while this is on are raised.
        mulg_engine_set_thread_priorities(context.settings.mulg.engine.prioritizeGameThreads)
        if context.settings.mulg.engine.prioritizeGameThreads {
            try? context.hooks.claim("pthread_setname_np (frame-critical game threads to performance-core QoS)", owner: id, kind: .interpose)
        }

        // Interposed at load time: the output units and queues the game creates, silenced while it is muted.
        try? context.hooks.claim("AudioComponentInstanceNew, AudioComponentInstantiate, AudioQueueNewOutput(WithDispatchQueue), AudioQueueSetParameter, AudioQueueDispose (mute when not in focus)",
                                 owner: id, kind: .interpose)

        // Interposed at load time for every game (upstream did the same).
        try? context.hooks.claim("dyld_get_active_platform", owner: id, kind: .interpose, privateAPI: true)

        if context.settings.rootWorkDir {
            FileManager.default.changeCurrentDirectoryPath("/")
        }

        if context.settings.mulg.engine.readAhead {
            // Build 864's roots: the bundle and the container. Build 865 also read the game's
            // external downloaded data, traced through the open/fopen hooks; that was removed
            // while hunting a freeze later traced to 192 kHz audio. Learning now samples open
            // files from a utility queue instead, and stays within these roots.
            let roots = Self.readAheadRoots(bundle: bundleURL, home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
            let budget = Self.readAheadBudget(physical: Int64(ProcessInfo.processInfo.physicalMemory),
                                              reclaimable: Self.reclaimableMemory())
            let trace = context.paths.diagnosticsDirectory(for: context.bundleIdentifier)
                .appendingPathComponent(LoadingTrace.fileName)
            let cancelled: @Sendable () -> Bool = { [self] in readAheadCancelled.withLock { $0 } }
            DispatchQueue.global(qos: .utility).async {
                EngineCoreModule.readAhead(roots: roots, budget: budget,
                                           learned: LoadingTrace.learned(at: trace, roots: roots), cancelled: cancelled)
            }
            LoadingTrace.record(roots: roots, to: trace, cancelled: cancelled)
            context.events.subscribe(GameClosing.self) { [weak self] _ in
                self?.readAheadCancelled.withLock { $0 = true }
            }
            context.events.subscribe(SettingsChanged.self) { [weak self] event in
                if !event.new.mulg.engine.readAhead {
                    self?.readAheadCancelled.withLock { $0 = true }
                }
            }
        }
    }

    public func activate(_ context: ModuleContext) {
        // This optimization does not need to initialize IOSurface/Metal inside a dyld
        // constructor. Once the scene is active, reuse the game's shared native device.
        if context.settings.mulg.engine.maximizeShaderCompilation, let bridge = context.bridge,
           let device = MTLCreateSystemDefaultDevice(), bridge.maximizeShaderCompilation?(on: device) == true {
            context.logger(for: id).info("Shader compilation on all cores")
        }
        #if targetEnvironment(macCatalyst)
        // Native fullscreen must remain available with optional display features off,
        // in recovery, and with any fixed-pixel render preset.
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            Self.allowNativeFullscreen(scene)
        }
        if fullscreenSceneObserver == nil {
            fullscreenSceneObserver = NotificationCenter.default.addObserver(
                forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { notification in
                nonisolated(unsafe) let object = notification.object
                MainActor.assumeIsolated {
                    if let scene = (object as? UIWindow)?.windowScene { Self.allowNativeFullscreen(scene) }
                }
            }
            context.events.subscribe(GameClosing.self) { [weak self] _ in
                guard let self, let observer = self.fullscreenSceneObserver else { return }
                NotificationCenter.default.removeObserver(observer)
                self.fullscreenSceneObserver = nil
            }
        }
        #endif
        #if canImport(UIKit) && !os(watchOS)
        if let bridge = context.bridge {
            // Focus, minimising and hiding reach the game as the iOS lifecycle.
            let lifecycle = GameLifecycle(keepRunningUnfocused: context.settings.mulg.engine.keepRunningUnfocused)
            bridge.observeWindowFocus?({ focused, onScreen in
                lifecycle.windowChanged(focused: focused, onScreen: onScreen)
            })
            muteWhenUnfocused(context, bridge: bridge)
            context.events.subscribe(SettingsChanged.self) { [weak lifecycle] event in
                guard event.old.mulg.engine.keepRunningUnfocused != event.new.mulg.engine.keepRunningUnfocused else { return }
                mulg_engine_set_keep_active(event.new.mulg.engine.keepRunningUnfocused)
                lifecycle?.setKeepRunningUnfocused(event.new.mulg.engine.keepRunningUnfocused)
            }
            // Closing the window ends the game like iOS ends an app, so it can save first.
            // The window close and the termination request both arrive here; the first one wins.
            var closeStarted = false, closingPublished = false
            let close: () -> Void = { [weak bridge, weak context] in
                guard !closeStarted else { return }
                closeStarted = true
                if !closingPublished { closingPublished = true; context?.events.publish(GameClosing()) }
                guard let context else { return }
                let marker = context.paths.safeModeMarker(for: context.bundleIdentifier)
                let closingRecord = try? Data(contentsOf: marker)
                GameShutdown.run(lifecycle: lifecycle, settings: context.settings.mulg.engine,
                                 logger: context.logger(for: .engine), onDeadline: {
                    // Normal termination may have cleared this marker before a native callback
                    // stalled. Restore the closing record so a forced exit remains incomplete.
                    if let closingRecord { try? closingRecord.writeBeside(to: marker) }
                }) {
                    context.events.publish(GameShutdownFinished())
                    bridge?.terminateApplication()
                }
            }
            bridge.observeWindowClosing(close)
            bridge.observeTermination?(close)
            // ⌘Q twice: one keystroke after ⌘Tab quit Ragnarok mid-play (2026-10-09, a key equivalent,
            // not a crash). The menu, the Dock and Mulg still quit at once.
            let quitWarning: () -> Void = { [weak context] in
                context?.notices.show(Notice("Press ⌘Q again to quit", style: .warning, duration: .seconds(2), important: true))
            }
            bridge.guardQuitShortcut?(context.settings.mulg.engine.confirmQuitShortcut, warn: quitWarning)
            bridge.keepForegroundOnOtherSpaces?(context.settings.mulg.engine.keepForegroundOnOtherSpaces)
            context.events.subscribe(SettingsChanged.self) { [weak bridge] change in
                guard change.old.mulg.engine.confirmQuitShortcut != change.new.mulg.engine.confirmQuitShortcut else { return }
                bridge?.guardQuitShortcut?(change.new.mulg.engine.confirmQuitShortcut, warn: quitWarning)
            }
            context.events.subscribe(SettingsChanged.self) { [weak bridge] change in
                let keep = change.new.mulg.engine.keepForegroundOnOtherSpaces
                guard change.old.mulg.engine.keepForegroundOnOtherSpaces != keep else { return }
                bridge?.keepForegroundOnOtherSpaces?(keep)
            }
            // The cursor, clicks and keymapped presses stay in the game window while it is played.
            bridge.confinePointer?(context.settings.mulg.engine.confinePointer)
            context.events.subscribe(SettingsChanged.self) { [weak bridge] change in
                let confine = change.new.mulg.engine.confinePointer
                guard change.old.mulg.engine.confinePointer != confine else { return }
                bridge?.confinePointer?(confine)
            }
            // A quit UIKit defers (it waits for the game's background tasks) still ends by the shutdown
            // deadline: a game that keeps starting tasks otherwise never quits (Ragnarok, 2026-10-09).
            bridge.observeDeferredTermination? { [weak context] in
                guard let context else { return }
                if !closingPublished { closingPublished = true; context.events.publish(GameClosing()) }
                let marker = context.paths.safeModeMarker(for: context.bundleIdentifier)
                let closingRecord = try? Data(contentsOf: marker)
                GameShutdown.armDeadline(settings: context.settings.mulg.engine, logger: context.logger(for: .engine)) {
                    if let closingRecord { try? closingRecord.writeBeside(to: marker) }
                }
            }
        }
        forwardMemoryPressure(context)
        #endif
        watchSettings(context)
    }

    #if targetEnvironment(macCatalyst)
    private static func allowNativeFullscreen(_ scene: UIWindowScene) {
        guard scene.session.role == .windowApplication else { return }
        scene.sizeRestrictions?.allowsFullScreen = true
    }
    #endif

    public func imagesChanged(_ context: ModuleContext) {
        if mulg_engine_install_lifecycle_delegate_hooks() > 0 {
            try? context.hooks.claim("Game lifecycle delegates (keep-running suspend policy)", owner: id, kind: .swizzle)
        }
        _ = mulg_engine_install_continued_processing_hooks()
        _ = mulg_engine_install_compat_hooks(bundleURL.map(Self.isUnrealEngine(bundleURL:)) ?? false,
                                             context.settings.checkMicPermissionSync)
    }
}

extension EngineCoreModule {
    /// Watches the settings folder, so a change made in the Mulg app reaches the running game
    /// (§7). Files are written atomically (a rename), which shows up as a write to the folder.
    /// Writes come in bursts (a slider, several games at once), so one reload covers 0.3 s, and
    /// only when this game's file changed: the folder holds every game's settings.
    func watchSettings(_ context: ModuleContext) {
        let file = context.paths.settingsFile(for: context.bundleIdentifier)
        let folder = file.deletingLastPathComponent()
        settingsFingerprint = Self.fingerprint(of: file)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            context.logger(for: id).error("Cannot create settings folder: \(String(describing: error), privacy: .public)")
            return
        }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            context.logger(for: id).notice("Settings folder not watched; changes apply on the next launch")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self, weak context] in
            MainActor.assumeIsolated {
                guard let self, !self.reloadPending else { return }
                self.reloadPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak context] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.reloadPending = false
                        let fingerprint = Self.fingerprint(of: file)
                        guard fingerprint != self.settingsFingerprint else { return }
                        self.settingsFingerprint = fingerprint
                        context?.reloadSettings()
                    }
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        settingsWatch = source
        // Settings may have changed between runtime preparation and scene activation.
        // Read after installing the watcher so neither that gap nor a concurrent save is lost.
        context.reloadSettings()
    }

    /// File identity, size and modification time: an atomic save always changes the identity.
    nonisolated static func fingerprint(of file: URL) -> [Int]? {
        var info = stat()
        guard stat(file.path, &info) == 0 else { return nil }
        return [Int(info.st_ino), Int(info.st_size), info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec]
    }
}

extension EngineCoreModule {
    /// At most 2 GB, an eighth of the Mac's memory, and a quarter of what macOS can hand out right
    /// now, so a Mac already short of memory doesn't page out other apps to fill the file cache.
    nonisolated static func readAheadBudget(physical: Int64, reclaimable: Int64?) -> Int64 {
        min(Int64(2) << 30, physical / 8, (reclaimable ?? physical) / 4)
    }

    /// The bundle, Documents, Library and the Library download folders, links resolved. Documents and
    /// the download folders link to the game folder (GameDataStorage), and walking Library never follows
    /// a link, so the game's downloaded assets were outside read-ahead after the game data moved.
    nonisolated static func readAheadRoots(bundle: URL, home: URL) -> [URL] {
        let library = home.appendingPathComponent("Library")
        var roots: [URL] = []
        for root in [bundle, home.appendingPathComponent("Documents"), library]
            + GameDataLayout.downloadLibraryNames.map({ library.appendingPathComponent($0) }) {
            let resolved = root.resolvingSymlinksInPath()
            if !roots.contains(resolved) { roots.append(resolved) }
        }
        return roots
    }

    /// Disjoint free and inactive pages: a conservative read-ahead headroom estimate.
    nonisolated static func reclaimablePageCount(_ vm: vm_statistics64) -> Int64 {
        // XNU includes speculative pages in free_count; purgeable pages overlap
        // the active/inactive queues. Count disjoint free and inactive pages only.
        Int64(vm.free_count) + Int64(vm.inactive_count)
    }

    nonisolated static func reclaimableMemory() -> Int64? {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return reclaimablePageCount(vm) * Int64(getpagesize())
    }

    /// Advises the first 8 MB of big asset files, 1 MB at a time, at most 256 MB in all: the
    /// `learned` files first (LoadingTrace), then the first 512 entries found under each local root.
    nonisolated static func readAhead(roots: [URL], budget: Int64, learned: [URL] = [],
                                      cancelled: @Sendable () -> Bool = { false }) {
        guard budget > 0, !cancelled() else { return }
        let extensions: Set<String> = ["assets", "ress", "resource", "bundle", "unity3d", "pak", "utoc", "ucas", "bank", "blk"]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var left = min(budget, Int64(256) << 20)
        var advised = Set<String>()
        for url in learned {
            guard left > 0, !cancelled() else { return }
            // Local only, as for the roots below: a learned file on a network volume is not read ahead.
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .volumeIsLocalKey]),
                  values.volumeIsLocal == true, let size = values.fileSize else { continue }
            left -= advise(url, size: Int64(size), left: left, cancelled: cancelled)
            advised.insert(url.path)
        }
        for root in roots {
            guard left > 0, !cancelled() else { return }
            guard (try? root.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == true else { continue }
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            var visited = 0
            for case let url as URL in files {
                guard left > 0, !cancelled() else { return }
                visited += 1
                guard visited <= 512 else { break } // Per root, so a big bundle cannot starve the save folders.
                guard extensions.contains(url.pathExtension.lowercased()) else { continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let size = values.fileSize, size >= 8 << 20, !advised.contains(url.path) else { continue }
                left -= advise(url, size: Int64(size), left: left, cancelled: cancelled)
                advised.insert(url.path) // A real download folder is also walked as part of Library.
            }
        }
    }

    /// Advisory reads of the first 8 MB of `url` (at most `left` bytes); returns the bytes advised.
    private nonisolated static func advise(_ url: URL, size: Int64, left: Int64, cancelled: @Sendable () -> Bool) -> Int64 {
        guard left > 0, !cancelled() else { return 0 }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return 0 }
        defer { close(descriptor) }
        let length = min(size, left, Int64(8) << 20)
        var offset: Int64 = 0
        while offset < length && !cancelled() {
            var advice = radvisory(ra_offset: off_t(offset), ra_count: Int32(min(length - offset, 1 << 20)))
            guard fcntl(descriptor, F_RDADVISE, &advice) != -1 else { break }
            offset += Int64(advice.ra_count)
            usleep(50_000)
        }
        return offset
    }
}

#if canImport(UIKit) && !os(watchOS)
extension EngineCoreModule {
    /// macOS memory pressure reaches the game as the iOS memory warning (delegate call and
    /// notification), so it frees caches as it would on an iPhone. Mac Catalyst may send its own
    /// warning for the same pressure, so one is sent only if none was seen within 10 seconds.
    func forwardMemoryPressure(_ context: ModuleContext) {
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                   object: nil, queue: .main) { [weak self, weak context] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ContinuousClock.now
                self.lastMemoryWarning = now
                self.readAheadCancelled.withLock { $0 = true }
                // The dispatch source already reported this pressure: when it posted the warning itself,
                // or when Mac Catalyst sends its own warning for the same pressure within 10 seconds.
                if self.postingMemoryWarning { return }
                if let published = self.lastPressurePublished, published > now - .seconds(10) { return }
                self.lastWarningPublished = now
                context?.events.publish(MemoryPressure())
            }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak context] in
            MainActor.assumeIsolated {
                self?.readAheadCancelled.withLock { $0 = true }
                // Skipped only when Mac Catalyst's own warning was just published for this pressure; this
                // source's own repeats (a warning, then critical) are all published, as before.
                let now = ContinuousClock.now
                let warnedJustNow = self?.lastWarningPublished.map { $0 > now - .seconds(10) } ?? false
                if !warnedJustNow {
                    self?.lastPressurePublished = now
                    context?.events.publish(MemoryPressure())
                }
                guard context?.settings.mulg.engine.memoryWarnings == true else { return }
                let pressure = ContinuousClock.now
                // Give Mac Catalyst's own warning a second to arrive first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak context] in
                    MainActor.assumeIsolated {
                        guard let context else { return }
                        self?.deliverMemoryWarning(context, pressure: pressure)
                    }
                }
            }
        }
        source.resume()
        memoryPressure = source
    }

    func deliverMemoryWarning(_ context: ModuleContext, pressure: ContinuousClock.Instant) {
        guard context.settings.mulg.engine.memoryWarnings else { return }
        if let last = lastMemoryWarning, last > pressure - .seconds(10) { return }
        let app = UIApplication.shared
        app.delegate?.applicationDidReceiveMemoryWarning?(app)
        postingMemoryWarning = true
        defer { postingMemoryWarning = false }
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: app)
    }
}
#endif

extension EngineCoreModule {
    nonisolated static func applyPrivacy(_ privacy: PrivacySettings) {
        mulg_engine_configure_privacy(privacy.microphone, privacy.camera, privacy.photos, privacy.location)
    }
}

#if canImport(UIKit) && !os(watchOS)
extension EngineCoreModule {
    static let muteCommand = "engine.muteWhenUnfocused"
    /// How long the game must be out of use before it falls silent.
    static let muteDelay = 0.15

    /// engine.muteWhenUnfocused: the game is silent while its window is not the one in use, and its
    /// sound returns the moment it is. Switchable in Mulg and from the in-game Controls menu.
    func muteWhenUnfocused(_ context: ModuleContext, bridge: any MacBridge) {
        var inUse = true
        var pendingMute: DispatchWorkItem?
        // Sound returns at once; silence waits 0.15 s of the game out of use, so a window animation that
        // briefly reports the window hidden (entering full screen) never cuts the sound.
        let logger = context.logger(for: id)
        let set: @MainActor (Bool) -> Void = { mute in
            guard mulg_engine_audio_muted() != mute else { return }
            mulg_engine_set_audio_muted(mute)
            logger.notice("Game sound \(mute ? "muted: not in use" : "restored", privacy: .public)")
        }
        let apply: @MainActor () -> Void = { [weak context] in
            pendingMute?.cancel()
            pendingMute = nil
            let mute = context?.settings.mulg.engine.muteWhenUnfocused == true && !inUse
            guard mute else { set(false); return }
            let work = DispatchWorkItem { MainActor.assumeIsolated { set(true) } }
            pendingMute = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.muteDelay, execute: work)
        }
        let changed: (Bool) -> Void = { using in
            MainActor.assumeIsolated {
                inUse = using
                apply()
            }
        }
        if bridge.observeGameInUse != nil {
            bridge.observeGameInUse?(changed)
        } else {
            // An older bridge: keyboard focus is the closest it reports.
            bridge.observeWindowFocus?({ focused, _ in changed(focused) })
        }
        let register: @MainActor () -> Void = { [weak context] in
            guard let context else { return }
            try? context.menus.register(MenuCommand(id: Self.muteCommand, title: "Mute When Not in Focus",
                                                    symbol: "speaker.slash", key: "", section: "sound",
                                                    isChecked: context.settings.mulg.engine.muteWhenUnfocused),
                                        owner: .engine) { [weak context] in
                guard let context else { return }
                let mute = !context.settings.mulg.engine.muteWhenUnfocused
                guard context.updateSettings({ $0.mulg.engine.muteWhenUnfocused = mute }) else { return }
                context.notices.show(Notice(mute ? "Muted while not in focus" : "Sound plays while not in focus",
                                            duration: .seconds(2)))
            }
        }
        register()
        apply()
        context.events.subscribe(SettingsChanged.self) { event in
            guard event.old.mulg.engine.muteWhenUnfocused != event.new.mulg.engine.muteWhenUnfocused else { return }
            register()
            apply()
        }
    }
}
#endif
