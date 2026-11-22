import Foundation
import MulgContracts
import MulgEngine
import os
#if canImport(UIKit)
import UIKit
#endif

/// The diagnostics module inside the game (PLAN.md §8): the Metal HUD for this game only,
/// input-to-present time (§6.1), FPS and 1% lows, and the files a bug report needs.
@MainActor
public final class DiagnosticsModule: GameModule {
    public let id = ModuleID.diagnostics

    public private(set) var frames = FrameStats()
    public private(set) var latency = LatencyTracker()
    weak var context: ModuleContext?
    private(set) var writer: Task<Void, Never>?
    private var activated = false
    private var closing = false
    private let signposter = MulgLog.signposter(.diagnostics)
    private var metalFX: MetalFXPreset?
    private var refreshRate: Int?
    private var hot = false
    /// The last presented frame, for the debugger's slow-frame lines.
    private var lastFrame: Double?
    #if canImport(UIKit) && !os(watchOS)
    private var overlay: PerformanceOverlayView?
    private var overlayTimer: Timer?
    #endif

    /// How often performance.json is refreshed while the game runs.
    public static let writeInterval: Duration = .seconds(60)

    public init() {}

    deinit { writer?.cancel() }

    /// The HUD and the debugger's Metal validation. Upstream switched the HUD on for every Metal
    /// app on the Mac (a global default). The environment of this process reaches this game
    /// only. Metal reads it when the first device is made, and engine, identity and graphics
    /// make one while preparing, so the runtime calls this before any module prepares. Metal 4
    /// queues come from that device and get the HUD and validation too.
    public static func setMetalEnvironment(_ settings: GameSettings, minimalRecovery: Bool = false) {
        // Clear inherited flags even in recovery. Explicit per-game overrides survive in
        // normal launches, and the same derived settings are already present in host launches.
        for name in LaunchEnvironment.managedMetalKeys { unsetenv(name) }
        let overrides = LaunchEnvironment.overrides(settings, minimalRecovery: minimalRecovery)
        for (name, value) in overrides where LaunchEnvironment.managedMetalKeys.contains(name) {
            setenv(name, value, 1)
        }
        // What the first device will validate; the debugger can only report it, never change it.
        launchValidation = (api: overrides["MTL_DEBUG_LAYER"] == "1", shaders: overrides["MTL_SHADER_VALIDATION"] == "1")
    }

    public func prepare(_ context: ModuleContext) throws {
        self.context = context
        let settings = context.settings
        // Frames only arrive while someone asked graphics for them, so listening costs nothing
        // until then.
        if settings.mulg.diagnostics.measureInputLatency || settings.mulg.diagnostics.performanceOverlay
            || Self.graphicsLog != nil {
            context.events.publish(FrameReportingRequested(requester: id, enabled: true))
        }
        context.events.subscribe(MetalFXStateChanged.self) { [weak self] change in
            self?.metalFX = change.enabled ? change.preset : nil
            Self.graphicsLog?.log("graphics", "MetalFX \(change.enabled ? "on, \(change.preset)" : "off")")
        }
        context.events.subscribe(DisplayRefreshRateChanged.self) { [weak self] change in
            self?.refreshRate = change.maximumRefreshRate
            Self.graphicsLog?.log("graphics", "Display refresh rate: \(change.maximumRefreshRate) Hz")
        }
        context.events.subscribe(MacHeatChanged.self) { [weak self] change in
            self?.hot = change.hot
            Self.cpuLog?.log("cpu", change.hot ? "The Mac is hot" : "The Mac cooled down")
        }
        context.events.subscribe(InputDelivered.self) { [weak self] input in
            guard let self, self.context?.settings.mulg.diagnostics.measureInputLatency == true else { return }
            self.latency.inputDelivered(arrival: MachClock.seconds(input.arrival),
                                       injected: MachClock.seconds(input.injected))
        }
        context.events.subscribe(FramePresented.self) { [weak self] frame in
            self?.framePresented(frame.presentedTime)
        }
        context.events.subscribe(WindowVisibilityChanged.self) { [weak self] change in
            Self.graphicsLog?.log("graphics", change.visible ? "Window shown" : "Window hidden")
            self?.lastFrame = nil
            guard let self, !change.visible else { return }
            // Save what was measured, then start over: a hidden window is a pause, not a slow frame.
            self.writePerformance()
            self.frames.reset()
        }
        // The last minute of play would otherwise be lost on quit.
        context.events.subscribe(GameClosing.self) { [weak self] _ in
            guard let self else { return }
            self.writePerformance()
            self.closing = true
            self.updatePerformanceWriter()
        }
        context.events.subscribe(DiagnosticNote.self) { Self.noteForCrashReports($0) }
        context.events.subscribe(SettingsChanged.self) { [weak self] change in
            self?.applyDebugging(change.new)
            self?.updatePerformanceWriter()
        }
    }

    public func activate(_ context: ModuleContext) {
        activated = true
        context.events.subscribe(ModulesStarted.self) { [weak self] started in
            self?.updateCrashContext(reports: started.reports)
            if let self, let context = self.context {
                Self.cpuLog?.log("modules", "\n" + self.moduleStates(reports: started.reports, context: context))
            }
        }
        startDebugLogging()
        registerOverlayHotkey(context)
        if context.settings.mulg.diagnostics.performanceOverlay {
            setOverlayVisible(true)
        }
        updatePerformanceWriter()
    }

    private func updatePerformanceWriter() {
        guard activated, !closing, let context,
              context.settings.mulg.engine.isModuleEnabled(.diagnostics),
              context.settings.mulg.diagnostics.measureInputLatency || context.settings.mulg.diagnostics.performanceOverlay else {
            writer?.cancel()
            writer = nil
            return
        }
        guard writer == nil else { return }
        writer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: DiagnosticsModule.writeInterval) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                self.writePerformance()
            }
        }
    }

    private func framePresented(_ time: Double) {
        guard let settings = context?.settings.mulg.diagnostics,
              settings.measureInputLatency || settings.performanceOverlay || Self.graphicsLog != nil else { return }
        if let debugger = Self.graphicsLog {
            if let last = lastFrame, time - last > Debugger.slowFrame {
                debugger.log("graphics", String(format: "Slow frame: %.0f ms", (time - last) * 1000))
            }
            lastFrame = time
        }
        frames.record(presentedTime: time)
        for sample in latency.framePresented(at: time) {
            signposter.emitEvent("inputToPresent", "\(sample.inputToPresentMs, format: .fixed(precision: 2)) ms, Mulg \(sample.processingMs, format: .fixed(precision: 3)) ms")
        }
    }

    // MARK: Files for bug reports (§8.3)

    struct Performance: Codable, Sendable {
        let date: Date
        let frames: FrameStats.Summary?
        let latency: LatencyTracker.Summary?
    }

    private func writePerformance() {
        guard let settings = context?.settings.mulg.diagnostics,
              settings.measureInputLatency || settings.performanceOverlay || Self.graphicsLog != nil else { return }
        let frames = self.frames.summary(), latency = self.latency.summary()
        // Nothing measured (not measuring, or just reset): keep the last report.
        guard frames != nil || latency != nil else { return }
        guard let context else { return }
        ReportWriter.shared.writeSnapshot(Performance(date: Date(), frames: frames, latency: latency),
            to: context.paths.diagnosticsDirectory(for: context.bundleIdentifier).appendingPathComponent("performance.json"),
            dateAsISO8601: true)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}

// MARK: - Performance overlay (§13.4)

extension DiagnosticsModule {
    /// What the overlay shows right now.
    public var overlayState: OverlayText.State {
        OverlayText.State(recentFPS: frames.recentFPS(), frames: frames.summary(), latency: latency.summary(),
                          metalFX: metalFX, refreshRate: refreshRate, hot: hot)
    }

    func registerOverlayHotkey(_ context: ModuleContext) {
        let text = context.settings.mulg.diagnostics.overlayHotkey
        guard let hotkey = Hotkey(text) else {
            context.logger(for: id).error("Invalid overlay hotkey '\(text, privacy: .public)'")
            return
        }
        do {
            try context.hotkeys.register(hotkey, owner: id, title: "Performance overlay") { [weak self] in
                self?.toggleOverlay()
            }
        } catch {
            context.logger(for: id).error("Overlay hotkey \(hotkey.description, privacy: .public) is taken")
        }
    }

    public func toggleOverlay() {
        #if canImport(UIKit) && !os(watchOS)
        setOverlayVisible(overlay == nil)
        #endif
    }

    func setOverlayVisible(_ visible: Bool) {
        #if canImport(UIKit) && !os(watchOS)
        guard let context else { return }
        if visible && (overlay != nil || Self.gameWindow() == nil) { return }
        guard context.updateSettings({ $0.mulg.diagnostics.performanceOverlay = visible }) else { return }
        if visible {
            guard overlay == nil, let window = Self.gameWindow() else { return }
            let view = PerformanceOverlayView(frame: .zero)
            window.addSubview(view)
            overlay = view
            view.show(OverlayText.lines(overlayState))
            overlayTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let overlay = self.overlay else { return }
                    overlay.superview?.bringSubviewToFront(overlay)
                    overlay.show(OverlayText.lines(self.overlayState))
                }
            }
        } else {
            overlayTimer?.invalidate()
            overlayTimer = nil
            overlay?.removeFromSuperview()
            overlay = nil
        }
        // Keep frame reports while the overlay, latency measuring or the debugger needs them.
        let measuring = context.settings.mulg.diagnostics.measureInputLatency || Self.graphicsLog != nil
        context.events.publish(FrameReportingRequested(requester: id, enabled: visible || measuring))
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    static func gameWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
    #endif
}
