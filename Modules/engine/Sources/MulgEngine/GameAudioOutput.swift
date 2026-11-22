import Foundation
import MulgBridge
import MulgContracts
import MulgEngineHooks
#if canImport(UIKit) && !os(watchOS)
import AVFAudio
#endif

/// Launch-scoped hardware policy. A game's client formats and real session getters stay native.
@MainActor
final class GameAudioOutput {
    private weak var context: ModuleContext?
    private let settings: AudioOutputSettings
    private var report: AudioOutputReport
    private var observers: [NSObjectProtocol] = []
    private var stopped = false
    private var sessionChangePending = false
    private var sessionQueriesAllowed = false

    init(context: ModuleContext) {
        self.context = context
        settings = context.settings.mulg.engine.audioOutput
        report = AudioOutputReport(processIdentifier: ProcessInfo.processInfo.processIdentifier)
    }

    func start() {
        guard let context else { return }
        guard !context.launch.isMinimal else {
            report.state = "recovery"
            report.message = "Device-format protection is disabled during minimal launch recovery."
            saveReport(); return
        }
        guard let bridge = context.bridge,
              bridge.responds(to: NSSelectorFromString("configureAudioOutputWithSampleRate:bitDepth:protect:report:")) else {
            report.state = "unsupported"
            report.message = "This runtime's macOS bridge does not support device-format protection."
            saveReport(); return
        }

        do {
            let installed = mulg_engine_install_audio_hooks()
            let targets: [(MulgEngineAudioHook, String)] = [
                (.preferredRate, "AVAudioSession.setPreferredSampleRate:error:"),
                (.active, "AVAudioSession.setActive:error:"),
                (.activeOptions, "AVAudioSession.setActive:withOptions:error:")
            ]
            for (flag, target) in targets {
                if installed.contains(flag) { try? context.hooks.claim(target, owner: .engine, kind: .swizzle) }
                else { context.hooks.recordMissing(target, owner: .engine, kind: .swizzle) }
            }
        }

        // CoreAudio can synchronously contact AVFoundation services and load more images.
        // Hooks are ready before the game starts, but device work waits until dyld has finished.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.sessionQueriesAllowed = true
            bridge.configureAudioOutput?(sampleRate: AudioOutputSettings.iPadSampleRate, bitDepth: self.settings.depth.bits,
                                         protect: true) { [weak self] value in
                MainActor.assumeIsolated { self?.receive(value) }
            }
        }
        context.events.subscribe(GameShutdownFinished.self) { [weak self] _ in self?.stop() }
        #if canImport(UIKit) && !os(watchOS)
        for name in [AVAudioSession.routeChangeNotification, AVAudioSession.interruptionNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionChanged() }
            })
        }
        #endif
    }

    private func receive(_ value: NSDictionary) {
        guard !stopped else { return }
        func rate(_ key: String) -> Double {
            let rate = (value[key] as? NSNumber)?.doubleValue ?? 0
            return rate.isFinite && rate >= 0 ? rate : 0
        }
        report.deviceName = value["deviceName"] as? String ?? "Audio output"
        report.requestedSampleRate = rate("requestedSampleRate")
        report.preferredSessionRate = rate("preferredSessionRate")
        report.sampleRate = rate("sampleRate")
        report.bitDepth = (value["bitDepth"] as? NSNumber)?.intValue ?? 0
        report.floatingPoint = (value["floatingPoint"] as? NSNumber)?.boolValue ?? false
        report.availableSampleRates = (value["availableSampleRates"] as? [NSNumber] ?? [])
            .map(\.doubleValue).filter { $0.isFinite && $0 > 0 }
        report.availableBitDepths = (value["availableBitDepths"] as? [NSNumber] ?? []).map(\.intValue).filter { $0 > 0 }
        report.state = value["state"] as? String ?? "unavailable"
        report.message = value["message"] as? String ?? "No device-format report."
        // The game's session asks for the iPad rate the device now runs at (48 kHz), so its own
        // mixer never resamples to an unusual device rate. If the device cannot run 48 kHz, the
        // bridge reports the actual rate instead and macOS converts.
        mulg_engine_configure_audio_preference(report.preferredSessionRate) { [weak self] in
            MainActor.assumeIsolated { self?.sessionChanged() }
        }
        saveReport()
    }

    /// Route changes, interruptions and the session's own callback arrive in bursts (a device
    /// switch sends several): one reassert and report covers each 250 ms.
    private func sessionChanged() {
        guard !stopped, !sessionChangePending else { return }
        sessionChangePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sessionChangePending = false
                guard !self.stopped else { return }
                self.context?.bridge?.reassertAudioOutput?()
                self.saveReport()
            }
        }
    }

    private func saveReport() {
        guard let context else { return }
        // Missing/older bridges report during runtime preparation, still inside dyld.
        // Reporting that unavailable service must not initialize AVAudioSession there.
        let sessionRate = sessionQueriesAllowed ? mulg_engine_audio_session_sample_rate() : 0
        report.sessionSampleRate = sessionRate.isFinite && sessionRate >= 0 ? sessionRate : 0
        report.updated = .now
        ReportWriter.shared.writeCompactSnapshot(report, to: context.paths.diagnosticsDirectory(for: context.bundleIdentifier)
            .appendingPathComponent("audio-output.json"))
    }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        mulg_engine_configure_audio_preference(0, nil)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        context?.bridge?.stopAudioOutput?(restore: settings.restoreOnExit)
    }
}
