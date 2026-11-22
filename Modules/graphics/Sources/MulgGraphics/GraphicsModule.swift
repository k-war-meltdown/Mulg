import Foundation
import Metal
import MulgContracts
import MulgEngine
import MulgGraphicsHooks
import QuartzCore
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Why the MetalFX layer cannot be switched on for this game right now (PLAN.md §5.2).
public enum MetalFXBlocker: Sendable, Equatable {
    /// The game uses MetalFX itself; never upscale twice (§5.2.7).
    case gameUsesOwnMetalFX(String)
    /// The game presents its main layer in a way the layer cannot intercept.
    case unsupportedPresentPath
    /// The GPU or pixel format is not supported by MetalFX.
    case notSupported(String)

    public var message: String {
        switch self {
        case .gameUsesOwnMetalFX(let feature):
            "This game uses MetalFX itself (\(feature)). Turn on its own MetalFX option instead."
        case .unsupportedPresentPath:
            "This game shows frames in a way the MetalFX layer can't upscale."
        case .notSupported(let reason):
            "MetalFX isn't available here: \(reason)."
        }
    }
}

/// The graphics module inside the game (PLAN.md §5): the MetalFX layer (upscaled into the game's
/// own layer) as an on/off feature with a hotkey, low latency, full-screen performance mode and vsync.
///
/// Experimental features stop in safe mode; stable presentation caps and measurement stay on.
@MainActor
public final class GraphicsModule: GameModule {
    public let id = ModuleID.graphics
    public let isExperimental = true

    public private(set) var metalFXEnabled = false
    public private(set) var preset: MetalFXPreset = .balanced
    /// The display module's battery saver is in effect (`BatterySaverChanged`, §7).
    public private(set) var batterySaver = false
    /// The preset the layer renders with: the chosen one, lightened while battery saver is on.
    public var activePreset: MetalFXPreset { preset.forBatterySaver(batterySaver) }
    public private(set) var blocker: MetalFXBlocker?
    private var recoverableBlocker = false
    private weak var blockedLayer: CAMetalLayer?
    public private(set) weak var mainLayer: CAMetalLayer?
    private var originalDisplaySync: Bool?
    private var interceptor: GraphicsInterceptor?
    private weak var context: ModuleContext?
    private var installedHooks: MulgGraphicsHook = []
    public private(set) var coreOnly = false
    /// Modules that currently want `FramePresented` events (the performance overlay, latency).
    private var frameReportRequests: Set<ModuleID> = []
    private var lastRenderReport: ContinuousClock.Instant?
    /// Presented frames since the last render report: count, first and last time, longest gap (seconds).
    private var presentedWindow: (frames: Int, first: CFTimeInterval, last: CFTimeInterval, longestGap: CFTimeInterval)?
    private let renderDiagnosticWriter = RenderDiagnosticWriter()
    private var geometryObserver: NSObjectProtocol?
    /// A window drag or full-screen switch is under way: the render surface is set once, when it ends.
    private var resizing = false
    /// Retries until Unity registered its internal calls (forced resolution); nil once settled.
    private var unityResolutionRetry: Timer?
    /// Unity's call was replaced, or this game has none to replace.
    private var unityResolutionSettled = false
    private var unityPlayerHookClaimed = false
    /// Keeps a Unity pipeline's renderScale at 1.0 (the game can set it again from its options); nil for
    /// games without IL2CPP's exports.
    private var unityRenderScaleTimer: Timer?
    private var unityRenderScaleUnavailable = false
    private var unityRenderScaleMisses = 0
    private let nativeScene = NativeSceneResolution()
    private var closing = false
    /// The display module's present limit (`FrameLimitChanged`); 0 frames per second is none.
    public private(set) var frameLimit = (framesPerSecond: 0, refreshRate: 60, variableRefresh: false)
    /// MetalFX is upscaling the main layer.
    private var upscaling: Bool { mulg_graphics_upscaling_layer() != nil }
    /// Frame pacing watch for `metalFX.automatic`, while MetalFX is off.
    private var automatic: AutomaticMetalFX?
    /// Automatic MetalFX acts once per launch, so a player who switches it off again keeps it off.
    private var automaticSpent = false

    public init() {}

    // MARK: Prepare

    public func prepareCore(_ context: ModuleContext) throws -> Bool {
        coreOnly = true
        try prepare(context)
        return true
    }

    public func prepare(_ context: ModuleContext) throws {
        self.context = context
        context.events.subscribe(GameClosing.self) { [weak self] _ in
            guard let self else { return }
            self.closing = true
            mulg_graphics_set_diagnostics_enabled(false)
            mulg_graphics_set_scene_trace_enabled(false)
            self.unityResolutionRetry?.invalidate()
            self.unityResolutionRetry = nil
            self.unityRenderScaleTimer?.invalidate()
            self.unityRenderScaleTimer = nil
        }
        #if canImport(UIKit) && !os(watchOS)
        geometryObserver = NotificationCenter.default.addObserver(
            forName: GameViewport.geometryChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.resizing else { return }
                self.updateRenderSurface()
            }
        }
        #endif
        context.events.subscribe(MemoryPressure.self) { [weak self] _ in
            self?.interceptor?.purgeCaches()
            mulg_graphics_purge_shader_cache()
        }
        // Archive saves wait longer while the game plays; a hidden window is a quiet moment.
        context.events.subscribe(WindowVisibilityChanged.self) { event in
            if !event.visible { mulg_graphics_save_shader_archives() }
        }
        let settings = context.settings
        mulg_graphics_set_scene_trace_enabled(!coreOnly && settings.mulg.diagnostics.debugGraphics
            && settings.mulg.graphics.nativeSceneResolution)
        metalFXEnabled = !coreOnly && settings.mulg.graphics.metalFX.enabled
        preset = settings.mulg.graphics.metalFX.preset
        applyConfig(settings)
        context.events.subscribe(FrameReportingRequested.self) { [weak self, weak context] request in
            guard let self, let context else { return }
            if request.enabled {
                self.frameReportRequests.insert(request.requester)
            } else {
                self.frameReportRequests.remove(request.requester)
            }
            self.applyConfig(context.settings)
        }
        context.events.subscribe(BatterySaverChanged.self) { [weak self, weak context] event in
            guard let self, let context else { return }
            self.batterySaverChanged(active: event.active, context: context)
        }
        context.events.subscribe(SettingsChanged.self) { [weak self, weak context] event in
            guard let self, let context else { return }
            self.settingsChanged(from: event.old, context: context)
        }
        context.events.subscribe(FrameLimitChanged.self) { [weak self, weak context] event in
            guard let self, let context else { return }
            self.frameLimit = (event.framesPerSecond, event.refreshRate, event.variableRefresh)
            self.automatic?.target = AutomaticMetalFX.target(framesPerSecond: event.framesPerSecond)
            self.applyConfig(context.settings)
        }

        // A main-queue block is much cheaper than a Task per signal on the render path.
        let interceptor = GraphicsInterceptor { [weak self] signal in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.handle(signal)
                }
            }
        }
        self.interceptor = interceptor
        mulg_graphics_set_delegate(interceptor)

        var attempted: MulgGraphicsHook = []
        installedHooks = mulg_graphics_install_presentation_hooks(!coreOnly, &attempted)
        claimHooks(installed: installedHooks, attempted: attempted, context: context)
        if !installedHooks.isSuperset(of: [.layerDrawableSize, .layerNextDrawable]) {
            blocker = .notSupported("presentation hooks could not be installed")
        }
        context.bridge?.observeLiveResize?({ [weak self] resizing in
            MainActor.assumeIsolated {
                guard let self, !self.closing else { return }
                mulg_graphics_set_live_resize(resizing)
                self.resizing = resizing
                // Each animation frame used to set the scale and call the engine's resize as well as the
                // engine's own resize: two reallocations a frame. Now once, at the final size.
                if !resizing { self.updateRenderSurface() }
            }
        })
        context.bridge?.observeDisplayChanges { [weak self, weak context] _ in
            guard let self, let context else { return }
            self.applyConfig(context.settings)
        }
        // Direct-to-display (§5.4): no panels on top of a full-screen game that wants it.
        context.notices.hideWhile = { [weak self, weak context] in
            guard let self, let context, context.bridge?.isFullscreen == true else { return false }
            return !self.coreOnly && (self.upscaling || context.settings.mulg.graphics.fullScreenPerformanceMode)
        }
        updateAutomaticMetalFX(context: context)
    }

    /// Starts or stops the frame pacing watch behind `metalFX.automatic` (opt-in): it needs present
    /// times, which are only collected while some module asks for them.
    private func updateAutomaticMetalFX(context: ModuleContext) {
        guard !closing else { return }
        let wanted = !coreOnly && !automaticSpent && !metalFXEnabled && blocker == nil
            && context.settings.mulg.graphics.metalFX.automatic
        guard wanted != (automatic != nil) else { return }
        if wanted {
            automatic = AutomaticMetalFX(target: AutomaticMetalFX.target(framesPerSecond: frameLimit.framesPerSecond))
            frameReportRequests.insert(id)
        } else {
            automatic = nil
            frameReportRequests.remove(id)
        }
        applyConfig(context.settings)
    }

    func applyConfig(_ settings: GameSettings) {
        guard !closing else { return }
        mulg_graphics_set_diagnostics_enabled(!coreOnly && settings.mulg.diagnostics.debugGraphics)
        mulg_graphics_set_scene_trace_enabled(!coreOnly && settings.mulg.diagnostics.debugGraphics
            && settings.mulg.graphics.nativeSceneResolution)
        mulg_graphics_set_render_height(settings.mulg.display.retina ? Int32(settings.targetRenderHeight ?? 0) : 0)
        // Retina off (display.retina) renders one pixel per point, so the full-resolution guard must not raise it.
        mulg_graphics_set_full_resolution(!coreOnly && settings.mulg.graphics.fullResolution && settings.mulg.display.retina)
        // Frame-rate unlock (display.uncapFrameRate, on with "This display" too): present minimums of
        // 1/60 or 1/30 s shorten to the unlock target's frame time.
        let unlocked = settings.mulg.display.uncapFrameRate || ResolutionMode(setting: settings.resolution) == .display
        let unlockTarget = frameLimit.framesPerSecond > 0 ? frameLimit.framesPerSecond : frameLimit.refreshRate
        mulg_graphics_set_unlocked_frame_duration(!coreOnly && unlocked && unlockTarget > 60 ? 1 / Double(unlockTarget) : 0)
        let vsyncOff = !coreOnly && settings.mulg.graphics.vsyncOff
        let measure = settings.mulg.diagnostics.measureInputLatency || settings.mulg.diagnostics.performanceOverlay
            || !frameReportRequests.isEmpty
        mulg_graphics_configure(MulgGraphicsConfig(
            lowLatency: settings.mulg.display.lowLatency ? 1 : 0,
            makeLayersOpaque: !coreOnly && context?.bridge?.isFullscreen == true
                && settings.mulg.graphics.fullScreenPerformanceMode ? 1 : 0,
            renderPercent: Int32(metalFXEnabled ? activePreset.renderPercent : 100),
            raiseRenderThreadPriority: !coreOnly && settings.mulg.graphics.raiseRenderThreadPriority ? 1 : 0,
            reportPresentTimes: measure ? 1 : 0,
            refreshesPerFrame: FrameLimiter.refreshesPerFrame(framesPerSecond: frameLimit.framesPerSecond,
                                                              refreshRate: frameLimit.refreshRate, vsyncEnabled: !vsyncOff),
            refreshPeriod: 1 / FrameLimiter.refreshRate(frameLimit.refreshRate),
            variableRefresh: frameLimit.variableRefresh || vsyncOff ? 1 : 0,
            justInTimeFrameStart: !coreOnly && !vsyncOff && settings.mulg.graphics.justInTimeFrameStart ? 1 : 0,
            vsyncDisabled: vsyncOff ? 1 : 0))
        if let mainLayer {
            mulg_graphics_update_render_surface(mainLayer, Self.renderSurfaceHeight(settings))
            mulg_graphics_apply_layer_config(mainLayer)
        }
        applyForcedResolution(settings)
    }

    /// Shader archive (§5.6): the pipelines the game builds are kept in Mulg's own folder, one
    /// file per GPU and macOS build, because Metal can't use shaders compiled for another. macOS
    /// keeps its own shader cache between launches too; this one also survives reinstalls,
    /// updates of the game and the system clearing that cache.
    private func startShaderArchive(context: ModuleContext) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let folder = context.paths.shaderArchiveDirectory(for: context.bundleIdentifier)
        let name = String("\(device.name) \(ProcessInfo.processInfo.operatingSystemVersionString)"
            .map { $0.isLetter || $0.isNumber ? $0 : "-" })
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Self.pruneShaderArchives(in: folder, keeping: name, limit: Self.shaderArchiveLimit)
        // Metal 3 capture stays off for every game: it compiles each game pipeline a second time,
        // later, from a copy of the game's descriptor. By then the game may have released the
        // function's bitcode, and the driver crashed on it (Endfield 1.6.3, 2026-10-17:
        // dispatch_retain(NULL) under addRenderPipelineFunctionsWithDescriptor on Mulg's archive queue).
        // macOS keeps its own shader cache; Metal 4 capture records inside the game's own build.
        let archives = [
            (nil as Bool?,
             "\(mulg_graphics_device_class_name()).newRenderPipelineStateWithDescriptor:"),
            (mulg_graphics_start_metal4_shader_archive(folder.appendingPathComponent(name + ".mtl4archive")),
             "\(mulg_graphics_device_class_name()).newCompilerWithDescriptor:error:")
        ]
        for (started, target) in archives {
            switch started {
            case true?: try? context.hooks.claim(target, owner: id, kind: .swizzle, privateAPI: true)
            case false?: context.hooks.recordMissing(target, owner: id, kind: .swizzle)
            case nil: break
            }
        }
    }

    /// Whether an earlier launch found that the compiler rejects this game's shaders for archiving
    /// (`remember_archive_unsupported`). The marker names the game build, so an update retries.
    nonisolated static func archiveUnsupported(marker: URL, gameBuild: String) -> Bool {
        guard let saved = try? String(contentsOf: marker, encoding: .utf8) else { return false }
        if saved == gameBuild { return true }
        try? FileManager.default.removeItem(at: marker)
        return false
    }

    /// Disk kept for one game's shader archives.
    static let shaderArchiveLimit = Int(MulgGraphicsShaderArchiveLimit)

    /// Deletes archives Metal can no longer use (another GPU or macOS build, left-over partial
    /// saves of them), and this build's too once together they pass `limit` bytes.
    static func pruneShaderArchives(in folder: URL, keeping name: String, limit: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        // Names never contain a dot, so this matches only this build's files.
        let current = files.filter { $0.lastPathComponent.hasPrefix(name + ".") }
        let size = current.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        for file in files where size > limit || !current.contains(file) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func claimHooks(installed: MulgGraphicsHook, attempted: MulgGraphicsHook, context: ModuleContext) {
        let bufferClass = mulg_graphics_command_buffer_class_name()
        let drawableClass = mulg_graphics_drawable_class_name()
        let queueClass = mulg_graphics_metal4_queue_class_name()
        let names: [(MulgGraphicsHook, String)] = [
            (.layerDrawableSize, "CAMetalLayer.setDrawableSize:, drawableSize"),
            (.metalKitDrawableSize, "MTKView.drawableSize"),
            (.viewContentScale, "UIView.setContentScaleFactor:"),
            (.unityRenderingSize, "DisplayConnection.requestRenderingResolution:"),
            (.layerNextDrawable, "CAMetalLayer.nextDrawable"),
            (.commandBufferPresent, "\(bufferClass).presentDrawable:"),
            (.commandBufferCommit, "\(bufferClass).commit"),
            (.renderPassSizes, "\(bufferClass).renderCommandEncoderWithDescriptor:"),
            (.drawablePresent, "\(drawableClass).present"),
            (.drawablePresentedHandlers, "\(drawableClass).addPresentedHandler:"),
            (.drawableLayer, "\(drawableClass).layer"),
            (.metal4Present, "\(queueClass).signalDrawable:"),
            (.metalFXDetection, "MTLFXSpatialScalerDescriptor.newSpatialScalerWithDevice:")
        ]
        for (hook, target) in names where attempted.contains(hook) {
            if installed.contains(hook) {
                // Driver classes are private implementation classes (§12 #17).
                let isPrivate = [bufferClass, drawableClass, queueClass].contains { target.hasPrefix($0) }
                try? context.hooks.claim(target, owner: id, kind: .swizzle, privateAPI: isPrivate)
            } else {
                context.hooks.recordMissing(target, owner: id, kind: .swizzle)
            }
        }
    }

    // MARK: Activate

    public func activate(_ context: ModuleContext) {
        guard !coreOnly else { return }
        // Archive creation also creates Metal devices/driver services. Wait until the game
        // has entered its scene lifecycle rather than doing it inside a dyld initializer.
        if context.settings.mulg.graphics.shaderArchive {
            startShaderArchive(context: context)
        }
        let text = context.settings.mulg.graphics.metalFX.hotkey
        guard let hotkey = Hotkey(text) else {
            context.logger(for: id).error("Invalid MetalFX hotkey '\(text, privacy: .public)'")
            return
        }
        do {
            try context.hotkeys.register(hotkey, owner: id, title: "MetalFX on/off") { [weak self] in
                self?.toggleMetalFX()
            }
        } catch {
            context.logger(for: id).error("MetalFX hotkey \(hotkey.description, privacy: .public) is taken")
        }
    }

    // MARK: Signals from the render thread

    func handle(_ signal: GraphicsSignal) {
        guard !closing else {
            // Drain queued ownership without touching a renderer being torn down.
            _ = interceptor?.takeLayerCandidates()
            _ = interceptor?.takePresentedFrames()
            return
        }
        guard let context else { return }
        switch signal {
        case .layerCandidatesChanged:
            let activity = interceptor?.takeLayerCandidates() ?? []
            #if canImport(UIKit) && !os(watchOS)
            let selected = GameViewport.shared.drawing(activity.map { ($0.layer.value, $0.time) })
            mulg_graphics_set_main_layer(selected)
            if let selected {
                mainLayerChanged(to: selected, context: context)
            } else {
                // A focus or visibility transition can briefly hide the viewport while
                // Unity still renders it. Keep its density until a real surface is selected.
                stopUpscaling()
                restoreDisplaySync(context)
                mainLayer = nil
            }
            #else
            if let newest = activity.max(by: { $0.time < $1.time }) {
                mulg_graphics_set_main_layer(newest.layer.value)
                mainLayerChanged(to: newest.layer.value, context: context)
            }
            #endif
        case .gameUsesOwnMetalFX(let feature):
            guard blocker != .gameUsesOwnMetalFX(feature) else { return }
            block(.gameUsesOwnMetalFX(feature), context: context)
            context.events.publish(GameUsesOwnMetalFX(feature: feature))
        case .unsupportedPresentPath(let generation):
            guard interceptor?.isCurrent(generation: generation) == true else { return }
            block(.unsupportedPresentPath, context: context, recoverable: true)
        case .drawableUnavailable(let generation):
            guard interceptor?.drawableIsUnavailable(generation: generation) == true else { return }
            block(.notSupported("output drawables temporarily unavailable"), context: context, recoverable: true)
        case .upscaleFailing(let failure, let generation):
            guard interceptor?.upscaleIsFailing(generation: generation) == true else { return }
            block(.notSupported(String(describing: failure)), context: context, recoverable: true)
        case .gpuExecutionFailed(let message, let generation):
            guard interceptor?.isCurrent(generation: generation) == true else { return }
            block(.notSupported("GPU execution: " + message), context: context)
        case .framesPresented:
            for time in interceptor?.takePresentedFrames() ?? [] {
                if automatic?.record(presentedTime: time) == true {
                    automaticSpent = true
                    context.logger(for: id).notice("MetalFX switched on automatically: frames stayed unevenly below the target")
                    applyMetalFX(enabled: true, context: context)
                    updateAutomaticMetalFX(context: context)
                }
                context.events.publish(FramePresented(presentedTime: time))
                if var window = presentedWindow {
                    window.longestGap = max(window.longestGap, time - window.last)
                    window.frames += 1
                    window.last = time
                    presentedWindow = window
                } else {
                    presentedWindow = (1, time, time, 0)
                }
            }
            // Keeps the report current while the game plays (render targets change after loading).
            if let mainLayer, lastRenderReport.map({ $0.duration(to: .now) >= .seconds(10) }) ?? true {
                writeRenderReport(layer: mainLayer, context: context)
            }
        }
    }

    func mainLayerChanged(to layer: CAMetalLayer, context: ModuleContext) {
        guard !closing else { return }
        mulg_graphics_update_render_surface(layer, Self.renderSurfaceHeight(context.settings))
        applyForcedResolution(context.settings)
        defer { writeRenderReport(layer: layer, context: context) }
        guard layer !== mainLayer else {
            if metalFXEnabled { startUpscaling(context: context) }
            return
        }
        stopUpscaling()
        restoreDisplaySync(context)
        mainLayer = layer
        if recoverableBlocker, layer !== blockedLayer {
            blocker = nil
            recoverableBlocker = false
            blockedLayer = nil
            metalFXEnabled = !coreOnly && context.settings.mulg.graphics.metalFX.enabled
            applyConfig(context.settings)
        }
        mulg_graphics_set_main_layer(layer)
        context.bridge?.bindGameLayer?(layer)
        updateDisplaySync(context)
        if metalFXEnabled {
            startUpscaling(context: context)
        }
    }

    // MARK: MetalFX on/off

    private func writeRenderReport(layer: CAMetalLayer, context: ModuleContext) {
        guard !coreOnly && context.settings.mulg.diagnostics.debugGraphics else { return }
        guard lastRenderReport.map({ $0.duration(to: .now) >= .seconds(1) }) ?? true else { return }
        lastRenderReport = .now
        var report = mulg_graphics_render_geometry(layer) as? [String: Any] ?? [:]
        report["resolutionMode"] = context.settings.resolution
        report["metalFXEnabled"] = metalFXEnabled
        report["fullResolution"] = context.settings.mulg.graphics.fullResolution
        report["fullResolutionRaises"] = Int(mulg_graphics_full_resolution_raises())
        report["metalFXBlocker"] = blocker?.message ?? ""
        report.merge(mulg_graphics_forced_resolution_report() as? [String: Any] ?? [:]) { $1 }
        let nativeOutput = mulg_mobile_preset_output_report()
        report["unityEngineOutputResolution"] = nativeOutput
        if nativeOutput["ownsEngineValues"] as? Bool == true {
            report["forcedResolutionPath"] = "Unity engine rendering request"
        }
        report["renderPassSizes"] = mulg_graphics_render_pass_sizes()
        report["recentRenderPassSizes"] = mulg_graphics_recent_render_pass_sizes()
        report["nativeSceneResolutionVerified"] = false
        report["nativeSceneResolution"] = nativeScene.report
        if !coreOnly && context.settings.mulg.graphics.nativeSceneResolution {
            report["sceneAllocationTrace"] = mulg_graphics_scene_trace()
        }
        // The game's real frame rate since the last report: average and the longest single frame.
        if let window = presentedWindow, window.frames > 1, window.last > window.first {
            report["presentedFPS"] = (Double(window.frames - 1) / (window.last - window.first) * 10).rounded() / 10
            report["longestFrameMs"] = (window.longestGap * 10_000).rounded() / 10
        }
        presentedWindow = nil
        report.merge(mulg_graphics_unity_render_scale_report() as? [String: Any] ?? [:]) { $1 }
        let directory = context.paths.diagnosticsDirectory(for: context.bundleIdentifier)
        renderDiagnosticWriter.submit(report, to: directory.appendingPathComponent("rendering.json"))
    }

    /// The hotkey and the Performance tab switch (§5.2): on/off without restarting the game.
    public func toggleMetalFX() {
        guard let context else { return }
        setMetalFX(enabled: !metalFXEnabled, context: context)
    }

    public func setMetalFX(enabled: Bool, context: ModuleContext) {
        guard !closing, !coreOnly else { return }
        if enabled, let blocker {
            context.notices.show(Notice("MetalFX unavailable", lines: [blocker.message], style: .warning))
            return
        }
        guard context.updateSettings({ $0.mulg.graphics.metalFX.enabled = enabled }) else { return }
        applyMetalFX(enabled: enabled, context: context)
    }

    private func applyMetalFX(enabled: Bool, context: ModuleContext) {
        guard !closing else { return }
        guard enabled != metalFXEnabled else { return }
        if enabled, let blocker {
            context.notices.show(Notice("MetalFX unavailable", lines: [blocker.message], style: .warning))
            return
        }
        metalFXEnabled = enabled
        applyConfig(context.settings)
        if enabled {
            startUpscaling(context: context)
            if let blocker {
                if !context.settings.mulg.graphics.metalFX.enabled {
                    context.notices.show(Notice("MetalFX unavailable", lines: [blocker.message], style: .warning))
                }
                return
            }
        } else {
            stopUpscaling()
            // Switched off while the game runs: automatic MetalFX does not switch it back on.
            automaticSpent = true
        }
        updateAutomaticMetalFX(context: context)
        context.notices.show(Notice(enabled ? "MetalFX on: \(activePreset.label)" : "MetalFX off", duration: .seconds(2)))
        context.events.publish(MetalFXStateChanged(enabled: enabled, preset: activePreset))
    }

    /// Battery saver (§7): a lighter preset on battery or in Low Power Mode, the chosen one again
    /// afterwards. The chosen preset in the settings is never changed.
    func batterySaverChanged(active: Bool, context: ModuleContext) {
        guard !closing else { return }
        let before = activePreset
        batterySaver = active
        guard activePreset != before else { return }
        applyConfig(context.settings)
        guard metalFXEnabled else { return }
        mulg_graphics_refresh_render_size()
        context.notices.show(Notice("MetalFX: \(activePreset.label)", duration: .seconds(2)))
        context.events.publish(MetalFXStateChanged(enabled: true, preset: activePreset))
    }

    private func startUpscaling(context: ModuleContext) {
        guard !closing, !upscaling, blocker == nil, let layer = mainLayer,
              mulg_graphics_layer_can_upscale(layer) else { return }
        guard let device = layer.device, MetalFXUpscaler.isSupported(on: device) else {
            block(.notSupported("this GPU"), context: context, recoverable: true)
            return
        }
        interceptor?.attach(layer)
        mulg_graphics_set_upscaling_layer(layer)
    }

    /// The MetalFX switch and preset, vsync and the present options follow the Mulg app while the
    /// game runs (§5.2, §7), so MetalFX can be switched from the app as well as by hotkey.
    func settingsChanged(from old: GameSettings, context: ModuleContext) {
        guard !closing else { return }
        let new = context.settings.mulg.graphics
        applyConfig(context.settings)
        guard !coreOnly else { return }
        if new.vsyncOff != old.mulg.graphics.vsyncOff {
            updateDisplaySync(context)
        }
        if new.metalFX.preset != preset {
            preset = new.metalFX.preset
            applyConfig(context.settings)
            mulg_graphics_refresh_render_size()
            if upscaling {
                context.notices.show(Notice("MetalFX: \(activePreset.label)", duration: .seconds(2)))
                context.events.publish(MetalFXStateChanged(enabled: true, preset: activePreset))
            }
        }
        // Only a change in the file: a switch the game refused (a blocker) is not asked again.
        if new.metalFX.enabled != old.mulg.graphics.metalFX.enabled, new.metalFX.enabled != metalFXEnabled {
            applyMetalFX(enabled: new.metalFX.enabled, context: context)
        }
        updateAutomaticMetalFX(context: context)
    }

    private func stopUpscaling() {
        mulg_graphics_set_upscaling_layer(nil)
        interceptor?.attach(nil)
    }

    private func restoreDisplaySync(_ context: ModuleContext) {
        if let mainLayer, let originalDisplaySync {
            _ = context.bridge?.setDisplaySyncEnabled(originalDisplaySync, on: mainLayer)
        }
        originalDisplaySync = nil
    }

    private func updateDisplaySync(_ context: ModuleContext) {
        guard !closing else { return }
        guard !coreOnly, context.settings.mulg.graphics.vsyncOff else {
            restoreDisplaySync(context)
            return
        }
        guard let mainLayer else { return }
        if originalDisplaySync == nil { originalDisplaySync = context.bridge?.displaySyncEnabled?(on: mainLayer) }
        // An older bridge cannot safely restore the layer, so it must not change it.
        if originalDisplaySync != nil { _ = context.bridge?.setDisplaySyncEnabled(false, on: mainLayer) }
    }

    /// Falls back to native rendering; surface-local failures can recover on another surface.
    func block(_ reason: MetalFXBlocker, context: ModuleContext, recoverable: Bool = false) {
        let wasRunning = upscaling
        blocker = reason
        recoverableBlocker = recoverable
        blockedLayer = recoverable ? mainLayer : nil
        stopUpscaling()
        if metalFXEnabled {
            metalFXEnabled = false
            applyConfig(context.settings)
            context.events.publish(MetalFXStateChanged(enabled: false, preset: activePreset))
        }
        context.logger(for: id).notice("MetalFX layer off: \(reason.message, privacy: .public)")
        if wasRunning || context.settings.mulg.graphics.metalFX.enabled {
            context.notices.show(Notice("MetalFX layer switched off", lines: [reason.message], style: .warning, duration: .seconds(6)))
        }
    }
}

extension MetalFXPreset {
    /// The preset while battery saver is on: nothing heavier than Performance (§7).
    public func forBatterySaver(_ active: Bool) -> MetalFXPreset {
        active && renderPercent > MetalFXPreset.performance.renderPercent ? .performance : self
    }
}

/// The present-side frame limiter (§6.1, §13.1). Display links are capped by the display module,
/// but many engines draw from their own loop and only block in `nextDrawable`; for them the cap
/// is enforced when each frame is presented, whichever present call the game uses. The hooks hold
/// whole refreshes on fixed-rate screens and exactly 1/limit on variable-rate screens in full
/// screen. Vsync-free presentation uses an absolute cap independent of display refresh.
public enum FrameLimiter {
    static func refreshRate(_ rate: Int) -> Double { Double(rate > 0 ? rate : 60) }
    /// Display refreshes per frame for a limit (2 for 60 at 120 Hz, 1.33 for 90), or 0 for none.
    public static func refreshesPerFrame(framesPerSecond: Int, refreshRate: Int, vsyncEnabled: Bool = true) -> Double {
        let refresh = Self.refreshRate(refreshRate)
        guard framesPerSecond > 0, !vsyncEnabled || Double(framesPerSecond) < refresh else { return 0 }
        return refresh / Double(framesPerSecond)
    }
}

extension GraphicsModule {
    /// A negative height selects one pixel per point and follows the view through resizing.
    nonisolated static func renderSurfaceHeight(_ settings: GameSettings) -> Int32 {
        settings.mulg.display.retina ? Int32(settings.targetRenderHeight ?? 0) : -1
    }

    /// The render view's scale for the selected resolution, and the engine told about it.
    fileprivate func updateRenderSurface() {
        guard !closing else { return }
        #if canImport(UIKit) && !os(watchOS)
        guard let context, let layer = GameViewport.shared.layer else { return }
        mulg_graphics_update_render_surface(layer, Self.renderSurfaceHeight(context.settings))
        applyForcedResolution(context.settings)
        #endif
    }
}

// MARK: - Forced resolution (graphics.forceRenderResolution)

extension GraphicsModule {
    /// Fixed presets retain both pixel dimensions. Height-only modes follow the window's
    /// shape, and automatic resolution follows its current native pixel density.
    nonisolated static func forcedTarget(points: CGSize, renderHeight: Int?, scale: CGFloat,
                                         fixedSize: (width: Int, height: Int)? = nil) -> (width: Int, height: Int)? {
        guard points.width > 0, points.height > 0, points.width.isFinite, points.height.isFinite else { return nil }
        if let fixedSize {
            guard fixedSize.width >= 2, fixedSize.height >= 2,
                  fixedSize.width <= 16384, fixedSize.height <= 16384 else { return nil }
            return fixedSize
        }
        let height = renderHeight.map(Double.init) ?? Double(points.height * scale)
        guard height.isFinite, height >= 2 else { return nil }
        let width = (height * Double(points.width / points.height)).rounded(.down)
        guard width >= 2, width <= 16384, height <= 16384 else { return nil }
        return (Int(width), Int(height.rounded(.down)))
    }

    /// Keeps the game at the target, or gives it back its own size when the setting is off.
    func applyForcedResolution(_ settings: GameSettings) {
        guard !closing else { return }
        #if canImport(UIKit) && !os(watchOS)
        let enabled = !coreOnly && settings.mulg.graphics.forceRenderResolution
        let nativeRequested = !coreOnly && settings.mulg.graphics.nativeSceneResolution
        guard enabled || nativeRequested || nativeScene.hasRequest || mulg_graphics_forced_resolution_enabled() else { return }
        var target: (width: Int, height: Int)?
        if let layer = GameViewport.shared.layer ?? mainLayer {
            let view = layer.delegate as? UIView
            let scale = !settings.mulg.display.retina ? 1
                : max(view?.contentScaleFactor ?? layer.contentsScale, view?.window?.screen.nativeScale ?? 0)
            target = Self.forcedTarget(points: layer.bounds.size,
                                       renderHeight: settings.mulg.display.retina ? settings.targetRenderHeight : nil,
                                       scale: scale,
                                       fixedSize: settings.mulg.display.retina ? settings.fixedRenderSize : nil)
        }
        // Mid-resize the size is not final; the end of the resize applies it.
        if enabled && (resizing || target == nil) { return }
        mulg_graphics_set_forced_resolution(enabled, Int32(target?.width ?? 0), Int32(target?.height ?? 0))
        if enabled { installUnityResolution() }
        // UnityFramework can load after the startup hooks: by the first render layer its classes exist.
        if enabled, !unityPlayerHookClaimed, mulg_graphics_install_unity_display_hook() {
            unityPlayerHookClaimed = true
            try? context?.hooks.claim("DisplayConnection.requestRenderingResolution:", owner: id, kind: .swizzle, privateAPI: false)
        }
        let unity = mulg_graphics_unity_apply_resolution()
        // Any Unity player, also without IL2CPP names: re-sends its last rendering-size request.
        let nativeOutput = mulg_mobile_preset_output_update(enabled)
        let player = nativeOutput == .unsupported ? mulg_graphics_unity_display_apply() : false
        if !unity && !player { _ = mulg_graphics_forced_apply_main_layer() }
        applyUnityRenderScale(enabled, nativeRequested: nativeRequested)
        #endif
    }

    /// The opt-in adapter replaces the legacy scaling path only after a successful capability
    /// probe. Output resolution, quality, MetalFX and viewport policies stay independent.
    private func applyUnityRenderScale(_ enabled: Bool, nativeRequested: Bool) {
        guard !closing else { return }
        let check: @MainActor (Bool, Bool) -> Bool = { [weak self] enabled, nativeRequested in
            guard let self, !self.closing else { return true }
            if self.resizing && enabled && nativeRequested { return false }
            // The display can become available after startup/surface discovery. Retry its
            // normal resize request before asking an inner-scene adapter to match that size.
            let nativeOutput = mulg_mobile_preset_output_update(enabled)
            if enabled && nativeOutput == .unsupported { _ = mulg_graphics_unity_display_apply() }
            self.nativeScene.reconcile(requested: nativeRequested, outputForced: enabled, metalFXActive: self.metalFXEnabled) {
                _ = mulg_graphics_unity_render_scale_apply(false)
            }
            if !self.nativeScene.managesScene && !self.unityRenderScaleUnavailable {
                if mulg_graphics_unity_render_scale_apply(enabled) == .unavailable {
                    self.unityRenderScaleMisses += 1
                    if self.unityRenderScaleMisses >= 30 { self.unityRenderScaleUnavailable = true }
                }
            }
            if !self.unityRenderScaleUnavailable || self.nativeScene.managesScene {
                mulg_graphics_unity_quality_apply(enabled && self.context?.settings.mulg.graphics.unityHighestQuality == true)
            }
            if self.nativeScene.needsRestoreRetry { return false }
            if nativeOutput == .waiting || mulg_mobile_preset_output_owns_values() { return false }
            return !enabled || (self.unityRenderScaleUnavailable && !self.nativeScene.managesScene && !self.nativeScene.waitingForEngine)
        }
        if check(enabled, nativeRequested) {
            unityRenderScaleTimer?.invalidate()
            unityRenderScaleTimer = nil
            return
        }
        guard unityRenderScaleTimer == nil else { return }
        unityRenderScaleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            let finished = MainActor.assumeIsolated {
                guard let self, let settings = self.context?.settings else { return true }
                let finished = check(mulg_graphics_forced_resolution_enabled(), !self.coreOnly && settings.mulg.graphics.nativeSceneResolution)
                if finished { self.unityRenderScaleTimer = nil }
                return finished
            }
            if finished { timer.invalidate() }
        }
    }

    /// Unity registers its internal calls after Mulg starts: retried every half second for two minutes.
    private func installUnityResolution() {
        guard !closing, unityResolutionRetry == nil, !unityResolutionSettled else { return }
        var attempts = 0
        let attempt: @MainActor () -> Bool = { [weak self] in
            guard let self, !self.closing else { return true }
            attempts += 1
            let state = mulg_graphics_unity_resolution_install()
            if state != .waiting { self.unityResolutionSettled = true }
            switch state {
            case .installed:
                if let context = self.context {
                    context.logger(for: self.id).notice("Forced resolution through Unity's Screen.SetResolution")
                    self.applyForcedResolution(context.settings)
                }
                return true
            case .waiting:
                guard attempts >= 240 else { return false }
                self.unityResolutionSettled = true
                return true
            default: return true
            }
        }
        if attempt() { return }
        unityResolutionRetry = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            let finished = MainActor.assumeIsolated {
                guard attempt() else { return false }
                self?.unityResolutionRetry = nil
                return true
            }
            // Keep the non-Sendable callback argument on its native run-loop thread.
            if finished { timer.invalidate() }
        }
    }
}
