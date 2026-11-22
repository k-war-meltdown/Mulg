import Foundation
import MulgContracts
import MulgDiagnosticsHooks
import MulgEngine
import OSLog
import Synchronization
#if canImport(Metal)
import Metal
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The per-game debugger (settings `diagnostics.debugger`, PLAN.md §8.3). Everything goes to
/// `debug.log` in the game's diagnostics folder with one write(2) per line, so every line
/// written before a crash is on disk. The log of the launch before is kept as
/// `debug-previous.log`, so the log of a crashed launch survives the next one. "Export
/// diagnostics" copies the whole folder, so both are in the zip.
final class Debugger: Sendable {
    static let fileName = "debug.log"
    static let previousFileName = "debug-previous.log"
    /// A frame this late is logged as slow.
    static let slowFrame: Double = 0.1

    /// Categories that can flood the log (Metal validation alone wrote 28 MB in 43 s). They stop
    /// at three quarters of the cap, so hangs, crashes and stops always still fit.
    static let noisyCategories: Set<String> = ["console", "log"]

    /// debug.log (-1 once closed), the bytes written to it, and whether the noisy categories
    /// were cut off.
    private let file: Mutex<(fd: Int32, written: Int, noisyFull: Bool)>
    /// Counts the near-identical lines of the noisy categories; never held while writing.
    private let repeats = Mutex(RepeatFilter())
    // Each part can be switched off and on again while the game runs (`apply`, `enable`).
    // Its loops end at their next wait once the part is off or was started again.
    private let cpuOn: Atomic<Bool>
    private let graphicsOn: Atomic<Bool>
    private let gameLogOn: Atomic<Bool>
    private let cpuGeneration = Atomic(0)
    private let gameLogGeneration = Atomic(0)
    /// Metal validation switched on at launch. Only a restart takes it off, or on.
    private let validatesAPI: Bool
    private let validatesShaders: Bool
    private let restartAsked = Atomic(false)
    var cpu: Bool { cpuOn.load(ordering: .relaxed) }
    var graphics: Bool { graphicsOn.load(ordering: .relaxed) }
    var gameLog: Bool { gameLogOn.load(ordering: .relaxed) }
    var running: Bool { cpu || graphics || gameLog }
    private let limit: Int
    /// Shared by every debugger of this launch, so restarting one keeps one time line.
    private let launched: UInt64

    // ponytail: one size cap per launch; past it the rest of the launch is lost, not the start.
    /// `continuing` reopens this launch's log after the debugger was switched off and on again,
    /// instead of starting a new one. Metal validation is whatever the launch set up.
    init?(directory: URL, settings: DiagnosticsSettings, limit: Int = 64 << 20,
          continuing: Bool = false, validation: (api: Bool, shaders: Bool)? = nil) {
        let current = directory.appendingPathComponent(Self.fileName)
        if !continuing {
            let files = FileManager.default
            let previous = directory.appendingPathComponent(Self.previousFileName)
            try? files.removeItem(at: previous)
            try? files.moveItem(at: current, to: previous)
        }
        let fd = open(current.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | (continuing ? 0 : O_TRUNC), 0o644)
        guard fd >= 0 else { return nil }
        var info = stat()
        let existing = continuing && fstat(fd, &info) == 0 ? Int(info.st_size) : 0
        file = Mutex((fd: fd, written: existing, noisyFull: false))
        cpuOn = Atomic(settings.debugCPU)
        graphicsOn = Atomic(settings.debugGraphics)
        gameLogOn = Atomic(settings.debugGameLog)
        // Apple's Metal validation is no longer started by Mulg; it is reported only when it is active.
        validatesAPI = validation?.api ?? false
        validatesShaders = validation?.shaders ?? false
        self.limit = limit
        launched = Self.firstStart
    }

    /// The first debugger of this launch (the runtime starts it before the game's code).
    private static let firstStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

    /// "%9.3f" of the seconds since launch, without Foundation: `log` runs on every thread,
    /// including while the main thread is still loading the game.
    static func timestamp(nanoseconds: UInt64) -> String {
        let milliseconds = nanoseconds / 1_000_000
        let fraction = String(milliseconds % 1000)
        let text = "\(milliseconds / 1000)." + String(repeating: "0", count: 3 - fraction.count) + fraction
        return String(repeating: " ", count: max(0, 9 - text.count)) + text
    }

    /// One line: seconds since launch, the category, the text. Nothing once closed. A flood of
    /// near-identical console or process-log lines is cut to a few lines and a count.
    func log(_ category: String, _ text: String) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if Self.noisyCategories.contains(category) {
            var summaries: [RepeatFilter.Summary] = []
            let admitted = repeats.withLock { $0.admit(category, text, now: now, summaries: &summaries) }
            writeSummaries(summaries, now: now)
            if !admitted { return }
        }
        emit(category, text, now: now)
    }

    /// What floods suppressed whose window ended (everything with `force`, when the log closes).
    func flushRepeats(force: Bool = false) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        writeSummaries(repeats.withLock { $0.drain(now: now, force: force) }, now: now)
    }

    private func writeSummaries(_ summaries: [RepeatFilter.Summary], now: UInt64) {
        for summary in summaries {
            emit(summary.category, "(\(summary.count) more lines like this, numbers aside) \(summary.example)", now: now)
        }
    }

    private func emit(_ category: String, _ text: String, now: UInt64) {
        let line = Self.timestamp(nanoseconds: now > launched ? now - launched : 0) + " [\(category)] \(text)\n"
        var bytes = Array(line.utf8)
        let limit = limit
        let noisy = Self.noisyCategories.contains(category)
        file.withLock { file in
            guard file.fd >= 0, file.written < limit else { return }
            if noisy {
                guard !file.noisyFull else { return }
                if file.written + bytes.count >= limit / 4 * 3 {
                    file.noisyFull = true
                    bytes = Array("Game console and process log lines stop here: the rest of the log is kept for hangs and crashes.\n".utf8)
                }
            }
            file.written += bytes.count
            if file.written >= limit {
                bytes += Array("The log is full (\(limit >> 20) MB); nothing more is written this launch.\n".utf8)
            }
            _ = bytes.withUnsafeBytes { write(file.fd, $0.baseAddress, $0.count) }
        }
    }

    /// Closes debug.log for the rest of the launch.
    func close() {
        flushRepeats(force: true)
        file.withLock { file in
            guard file.fd >= 0 else { return }
            _ = Darwin.close(file.fd)
            file.fd = -1
        }
    }

    /// Starts the background parts. `mulg_debug_watch_this_thread` must already have run on the
    /// main thread when `cpu` is on.
    func start() {
        if cpu { startCPU() }
        if gameLog { startGameLog() }
    }

    private func startCPU() {
        let generation = cpuGeneration.wrappingAdd(1, ordering: .relaxed).newValue
        file.withLock { mulg_debug_set_log($0.fd) }
        watchMainThread()
        sampleProcess(generation)
    }

    private func startGameLog() {
        let generation = gameLogGeneration.wrappingAdd(1, ordering: .relaxed).newValue
        captureConsole()
        captureProcessLog(generation)
    }

    /// Switches on, while the game runs, the parts `settings` switched on. CPU (hangs, samples,
    /// crash lines), the game log and slow-frame lines start now; Metal reads its validation
    /// switches once, before the first device, so validation that the launch did not set up
    /// waits for a restart. Returns the names of the parts that wait. Main thread only, because
    /// the hang watcher reads the calling thread.
    func enable(_ settings: DiagnosticsSettings) -> [String] {
        if settings.debugCPU && !cpu {
            mulg_debug_watch_this_thread()
            cpuOn.store(true, ordering: .relaxed)
            log("start", "CPU and crashes switched on")
            startCPU()
        }
        if settings.debugGraphics && !graphics {
            graphicsOn.store(true, ordering: .relaxed)
            log("start", "Graphics switched on")
        }
        if settings.debugGameLog && !gameLog {
            gameLogOn.store(true, ordering: .relaxed)
            log("start", "Game log switched on")
            startGameLog()
        }
        return []
    }

    /// Switches off the parts `settings` switched off, or all of them when `on` is false.
    /// debug.log is closed once every part is off. True when Metal validation is no longer
    /// wanted: only a restart takes it off, since the device made at launch keeps it and no
    /// Metal call removes it.
    @discardableResult
    func apply(_ settings: DiagnosticsSettings, on: Bool) -> Bool {
        if cpu && !(on && settings.debugCPU) {
            cpuOn.store(false, ordering: .relaxed)
            DiagnosticsModule.hangWatchdog.observeStalls(nil)
            mulg_debug_set_log(-1)
            log("stop", "CPU and crashes switched off")
        }
        if graphics && !(on && settings.debugGraphics) {
            graphicsOn.store(false, ordering: .relaxed)
            log("stop", "Graphics switched off")
        }
        let unwanted = (validatesAPI && !(on && settings.debugGraphics)) || (validatesShaders && !(on && settings.debugShaders))
        let restart = unwanted && !restartAsked.exchange(true, ordering: .relaxed)
        if restart {
            log("stop", "Metal validation switched off; it stays on until the game restarts")
        }
        if gameLog && !(on && settings.debugGameLog) {
            gameLogOn.store(false, ordering: .relaxed)
            mulg_debug_restore_console()  // the console reader then reads the rest and ends
            log("stop", "Game log switched off")
        }
        if !running {
            log("stop", "The debugger is off")
            close()
        }
        return restart
    }

    /// Hangs come from the shared main-thread watcher (`HangWatchdog`), which also writes freeze
    /// reports: a stall logs the main thread's backtrace, then how long the stall lasted.
    private func watchMainThread() {
        DiagnosticsModule.hangWatchdog.observeStalls { [weak self] stall in
            guard let self, self.cpu else { return }
            switch stall {
            case .began:
                log("cpu", "The main thread has not answered for \(HangWatchdog.stallThreshold) s. Its backtrace:")
                file.withLock { if $0.fd >= 0 { mulg_debug_backtrace($0.fd) } }
            case .ended(let seconds):
                log("cpu", String(format: "The main thread answered again after %.1f s.", seconds))
            }
        }
    }

    /// CPU use, memory footprint, threads and heat every 5 seconds.
    private func sampleProcess(_ generation: Int) {
        Task.detached(priority: .utility) { [self] in
            var last = (stats: mulg_debug_process_stats(), time: ProcessInfo.processInfo.systemUptime)
            while cpu && cpuGeneration.load(ordering: .relaxed) == generation {
                try? await Task.sleep(for: .seconds(5))
                guard cpu, cpuGeneration.load(ordering: .relaxed) == generation else { return }
                let now = (stats: mulg_debug_process_stats(), time: ProcessInfo.processInfo.systemUptime)
                let usage = (now.stats.cpuSeconds - last.stats.cpuSeconds) / (now.time - last.time) * 100
                flushRepeats()
                let heat = ["nominal", "fair", "serious", "critical"][min(ProcessInfo.processInfo.thermalState.rawValue, 3)]
                log("cpu", String(format: "CPU %.0f%% (100%% is one core), memory %llu MB, %u threads, ",
                                  usage, now.stats.footprint >> 20, now.stats.threads) + "heat \(heat)")
                last = now
            }
        }
    }

    /// The game's stdout and stderr, through a pipe, one log line per line printed.
    // ponytail: output still in the pipe when the game crashes is lost (at most one read), and so
    // are lines printed while the pipe is full: the game never waits for the debugger.
    private func captureConsole() {
        var ends: [Int32] = [0, 0]
        guard mulg_debug_console_pipe(&ends) == 0 else {
            log("console", "The console cannot be captured: \(String(cString: strerror(errno)))")
            return
        }
        mulg_debug_redirect_console(ends[1])
        Darwin.close(ends[1])
        let reader = ends[0]
        Thread.detachNewThread { [self] in
            Thread.current.name = "Mulg debugger: console"
            var buffer = [UInt8](repeating: 0, count: 16384)
            var pending: [UInt8] = []
            while true {
                let count = buffer.withUnsafeMutableBytes { read(reader, $0.baseAddress, $0.count) }
                // A reader that stopped early would leave the game blocked on a full pipe.
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                pending += buffer[..<count]
                while let newline = pending.firstIndex(of: 10) {
                    log("console", String(decoding: pending[..<newline], as: UTF8.self))
                    pending.removeSubrange(...newline)
                }
                if pending.count > 65536 {  // a very long line without a newline
                    log("console", String(decoding: pending, as: UTF8.self))
                    pending.removeAll()
                }
            }
        }
    }

    /// Every os_log and NSLog message of this process: the game's, Metal's (validation errors,
    /// GPU faults), UIKit's and Mulg's. Private values stay "<private>".
    // ponytail: read every 2 seconds, so the last 2 seconds before a crash are missing (the crash
    // report has the backtrace); messages sharing the last one's timestamp may be skipped.
    /// The log store drops, before they reach Swift, the system's per-event chatter: UIKit's event
    /// dispatch lines and routine network and XPC messages. Their errors and faults still come.
    nonisolated static var processLogFilter: NSPredicate {
        NSPredicate(format: "messageType == error OR messageType == fault OR NOT ((subsystem == %@ AND category == %@) OR subsystem IN %@)",
                    "com.apple.UIKit", "EventDispatch", ["com.apple.network", "com.apple.CFNetwork", "com.apple.xpc"])
    }

    private func captureProcessLog(_ generation: Int) {
        Task.detached(priority: .utility) { [self] in
            let store: OSLogStore
            do {
                store = try OSLogStore(scope: .currentProcessIdentifier)
            } catch {
                log("log", "The process log cannot be read: \(error.localizedDescription)")
                return
            }
            var last = Date.now
            let wanted = Self.processLogFilter
            while gameLog && gameLogGeneration.load(ordering: .relaxed) == generation {
                try? await Task.sleep(for: .seconds(2))
                guard gameLog, gameLogGeneration.load(ordering: .relaxed) == generation,
                      let entries = try? store.getEntries(at: store.position(date: last), matching: wanted) else { continue }
                for case let entry as OSLogEntryLog in entries where entry.date > last {
                    let source = entry.subsystem.isEmpty ? entry.sender : "\(entry.subsystem) \(entry.category)"
                    let level = entry.level == .error || entry.level == .fault ? "ERROR " : ""
                    log("log", "\(level)\(source): \(entry.composedMessage)")
                    last = entry.date
                }
            }
        }
    }
}

extension DiagnosticsModule {
    /// Set when the debugger is on; nil again once every part is switched off.
    static var debugger: Debugger?
    static var cpuLog: Debugger? { debugger?.cpu == true ? debugger : nil }
    static var graphicsLog: Debugger? { debugger?.graphics == true ? debugger : nil }
    /// debug.log already belongs to this launch: switching on again appends to it.
    private static var loggedThisLaunch = false
    /// The Metal validation this launch's environment asked for (`setMetalEnvironment`).
    static var launchValidation = (api: false, shaders: false)
    /// Parts already announced as waiting for a restart, so other setting changes stay quiet.
    private static var announcedWaiting: [String] = []

    /// Switching the debugger, a part of it or crash reports on or off in the Mulg app takes
    /// effect in the running game. Mulg no longer sets Metal validation (LaunchEnvironment strips it).
    func applyDebugging(_ settings: GameSettings) {
        guard let context else { return }
        let enabled = settings.mulg.engine.isModuleEnabled(.diagnostics)
        let diagnostics = settings.mulg.diagnostics
        let wanted = enabled && diagnostics.debugger && !context.launch.isMinimal
        if enabled && diagnostics.writesCrashReports && !context.launch.isMinimal {
            if !Self.crashReporterActive {
                Self.installCrashReporter(settings: settings, paths: context.paths, bundleIdentifier: context.bundleIdentifier)
                Self.setCrashContext("Stage: running (crash reports were switched on while the game ran)")
            }
        } else if Self.crashReporterActive {
            mulg_crash_uninstall()
            Self.hangWatchdog.stop()
            Self.crashReporterActive = false
        }

        let wasGraphics = Self.debugger?.graphics ?? false
        if let debugger = Self.debugger {
            if debugger.apply(diagnostics, on: wanted) {
                context.notices.show(Notice("Restart the game to switch Metal validation off",
                                            lines: ["The debugger stopped, but the game stays slower until it restarts."],
                                            duration: .seconds(6)))
            }
            if !debugger.running { Self.debugger = nil }
        }
        if wanted && (diagnostics.debugCPU || diagnostics.debugGraphics || diagnostics.debugGameLog || diagnostics.debugShaders) {
            let debugger: Debugger
            if let running = Self.debugger {
                debugger = running
            } else {
                let directory = context.paths.diagnosticsDirectory(for: context.bundleIdentifier)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var none = diagnostics
                none.debugCPU = false; none.debugGraphics = false; none.debugGameLog = false
                guard let started = Debugger(directory: directory, settings: none, continuing: Self.loggedThisLaunch,
                                             validation: Self.launchValidation) else {
                    context.logger(for: id).error("No debugger log in \(directory.path, privacy: .public)")
                    return
                }
                if !Self.loggedThisLaunch { started.log("start", Self.startLine(diagnostics, bundleIdentifier: context.bundleIdentifier)) }
                Self.loggedThisLaunch = true
                debugger = started
            }
            let waiting = debugger.enable(diagnostics)
            Self.debugger = debugger.running ? debugger : nil
            if !debugger.running { debugger.close() }
            if !waiting.isEmpty && waiting != Self.announcedWaiting {
                debugger.log("start", "Waiting for a restart: \(waiting.joined(separator: ", "))")
                context.notices.show(Notice("Restart the game to switch \(waiting.joined(separator: " and ")) on",
                                            lines: ["The rest of the debug log is running now."], duration: .seconds(6)))
            }
            Self.announcedWaiting = waiting
        } else {
            Self.announcedWaiting = []
        }
        let graphics = Self.debugger?.graphics ?? false
        if graphics != wasGraphics && !diagnostics.measureInputLatency && !diagnostics.performanceOverlay {
            context.events.publish(FrameReportingRequested(requester: id, enabled: graphics))
        }
    }

    private static func startLine(_ diagnostics: DiagnosticsSettings, bundleIdentifier: String) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let process = ProcessInfo.processInfo
        let on = [("cpu", diagnostics.debugCPU), ("graphics", diagnostics.debugGraphics),
                  ("shaders", diagnostics.debugShaders), ("game log", diagnostics.debugGameLog)]
            .filter { $0.1 }.map { $0.0 }
        return """
            Mulg \(MulgVersion.current), \(Date.now.ISO8601Format()). \(bundleIdentifier) \
            \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")). \
            \(process.operatingSystemVersionString), \(process.physicalMemory >> 30) GB, \(process.activeProcessorCount) cores. \
            Debugging: \(on.isEmpty ? "nothing" : on.joined(separator: ", ")).
            """
    }

    /// What only the running module can log: the GPU and memory warnings.
    func startDebugLogging() {
        #if canImport(Metal)
        Self.graphicsLog?.log("graphics", "GPU: \(MTLCreateSystemDefaultDevice()?.name ?? "none")")
        #endif
        #if canImport(UIKit) && !os(watchOS)
        guard Self.cpuLog != nil else { return }
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                   object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let stats = mulg_debug_process_stats()
                Self.cpuLog?.log("cpu", "Memory warning at \(stats.footprint >> 20) MB")
            }
        }
        #endif
    }

    /// The runtime calls this right after `installCrashReporter`, before any module prepares,
    /// so module start-up is in the log too.
    public static func startDebugger(settings: GameSettings, paths: ContainerPaths, bundleIdentifier: String,
                                     minimalRecovery: Bool = false) {
        let diagnostics = settings.mulg.diagnostics
        guard !minimalRecovery, settings.mulg.engine.isModuleEnabled(.diagnostics), diagnostics.debugger, debugger == nil else { return }
        let directory = paths.diagnosticsDirectory(for: bundleIdentifier)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let started = Debugger(directory: directory, settings: diagnostics) else {
            MulgLog.logger(.diagnostics).error("No debugger log in \(directory.path, privacy: .public)")
            return
        }
        started.log("start", startLine(diagnostics, bundleIdentifier: bundleIdentifier))
        loggedThisLaunch = true
        if diagnostics.debugCPU {
            mulg_debug_watch_this_thread()
        }
        started.start()
        debugger = started
    }
}
