import Foundation
import MulgDiagnosticsHooks
import Synchronization

/// The one main-thread watcher. A thread asks the main thread for an answer every second (every
/// half second while the debugger listens); nothing runs while neither user is on.
///
/// - Freeze reports (PLAN.md §8.3), on whenever crash reports are: when no answer comes for
///   `threshold` seconds, every thread's backtrace goes to `Hang-<unix time>.txt` while the game is
///   still frozen, so a force quit cannot lose it, and a second snapshot follows `followUp` seconds
///   later if it is still frozen: together they show which thread spins and which ones wait for it.
///   When the main thread answers again, the file is renamed `…-recovered.txt`, which keeps a slow
///   loading screen out of crash recovery.
/// - The debugger's stall lines (`observeStalls`): told after `stallThreshold` seconds without an
///   answer, and again when the answer comes.
// ponytail: a Mac that sleeps with the game open writes one recovered report on wake.
final class HangWatchdog: Sendable {
    static let threshold: Double = 5
    static let followUp: Double = 10
    static let reportsPerLaunch = 3
    static let stallThreshold: Double = 2

    enum Stall: Sendable {
        case began
        /// Seconds since the unanswered question was asked.
        case ended(Double)
    }

    private struct Target: Sendable {
        var directory: URL
        /// The folder as a plain path, made at `start`: while the main thread is frozen only POSIX calls
        /// run, never URL or FileManager work (a frozen process may hold the locks those want).
        var path: String
    }
    private let target = Mutex<Target?>(nil)
    private let stalls = Mutex<(@Sendable (Stall) -> Void)?>(nil)
    private let started = Atomic(false)

    /// Writes freeze reports to `directory`. `mulg_hang_watch_main_thread` must already have run on
    /// the main thread.
    func start(directory: URL) {
        // Made now, while the game runs normally, so a freeze report needs no Foundation file call.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Also here: a freeze that ended in a force quit never reaches the pruning after recovery.
        DiagnosticsModule.removeOldCrashReports(in: directory, prefix: "Hang-")
        target.withLock { $0 = Target(directory: directory, path: directory.path) }
        launch()
    }

    /// No more freeze reports until the next `start`; a report being written is finished.
    func stop() {
        target.withLock { $0 = nil }
    }

    /// Calls `handler` on the watcher thread when the main thread stalls and when it answers
    /// again. nil stops it.
    func observeStalls(_ handler: (@Sendable (Stall) -> Void)?) {
        stalls.withLock { $0 = handler }
        if handler != nil { launch() }
    }

    private func launch() {
        guard !started.exchange(true, ordering: .relaxed) else { return }
        Thread.detachNewThread { [self] in
            Thread.current.name = "Mulg hang watchdog"
            watch()
        }
    }

    private func watch() {
        let answer = DispatchSemaphore(value: 0)
        // Loading before the main queue first runs is not a hang.
        DispatchQueue.main.async { answer.signal() }
        answer.wait()
        var written = 0
        while true {
            let observer = stalls.withLock { $0 }
            Thread.sleep(forTimeInterval: observer == nil ? 1 : 0.5)
            let reporting = target.withLock { $0 != nil }
            guard reporting || observer != nil else { continue }
            let asked = ProcessInfo.processInfo.systemUptime
            // Every question gets exactly one wait that returns, so no stale answer is left over.
            DispatchQueue.main.async { answer.signal() }
            if let observer {
                guard answer.wait(timeout: .now() + Self.stallThreshold) == .timedOut else { continue }
                observer(.began)
            }
            let answered = answer.wait(timeout: .now() + Self.threshold - (observer == nil ? 0 : Self.stallThreshold)) == .success
            if !answered {
                report(&written, asked: asked, answer: answer)
            }
            observer?(.ended(ProcessInfo.processInfo.systemUptime - asked))
        }
    }

    /// The main thread has not answered for `threshold` seconds: writes a report if one is wanted,
    /// and returns once it answers.
    private func report(_ written: inout Int, asked: TimeInterval, answer: DispatchSemaphore) {
        guard written < Self.reportsPerLaunch, let report = writeReport() else {
            answer.wait()
            return
        }
        written += 1
        if answer.wait(timeout: .now() + Self.followUp) == .timedOut {
            append(to: report, "\n\nStill not answering after \(seconds(since: asked)) s. Second snapshot:\n", snapshot: true)
            answer.wait()
        }
        append(to: report, "\n\nThe main thread answered again after \(seconds(since: asked)) s.\n", snapshot: false)
        _ = rename(report, String(report.dropLast(".txt".count)) + "-recovered.txt")
        // The game runs again: Foundation is safe to use, so older reports are pruned now, not while frozen.
        if let directory = target.withLock({ $0?.directory }) {
            DiagnosticsModule.removeOldCrashReports(in: directory, prefix: "Hang-")
        }
    }

    private func seconds(since start: TimeInterval) -> String {
        String(format: "%.1f", ProcessInfo.processInfo.systemUptime - start)
    }

    /// POSIX calls only: a frozen process may hold locks that Foundation's file APIs want. (The folder
    /// was made at `start`, and older reports are pruned once the main thread answers again.)
    private func writeReport() -> String? {
        guard let target = target.withLock({ $0 }) else { return nil }
        _ = mkdir(target.path, 0o755)  // Removed while the game ran: made again, still without Foundation.
        let report = target.path + "/Hang-\(time(nil)).txt"
        let fd = open(report, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        put(fd, "Mulg hang report: the main thread has not answered for \(Int(Self.threshold)) s.\n\n")
        // The crash reports' live text: stage, module states and notes, then the launch header.
        mulg_crash_write_context(fd)
        put(fd, "\n\n")
        mulg_hang_snapshot(fd)
        return report
    }

    private func append(to report: String, _ text: String, snapshot: Bool) {
        let fd = open(report, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        put(fd, text)
        if snapshot { mulg_hang_snapshot(fd) }
    }

    private func put(_ fd: Int32, _ text: String) {
        var text = text
        text.withUTF8 { _ = write(fd, $0.baseAddress, $0.count) }
    }
}
