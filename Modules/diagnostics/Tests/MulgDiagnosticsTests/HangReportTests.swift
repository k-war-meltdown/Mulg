import Foundation
import MulgContracts
import MulgEngine
@testable import MulgDiagnostics
import MulgDiagnosticsHooks
import Synchronization
import Testing

@Suite("Freeze reports", .serialized)
struct HangReportTests {
    @Test("A snapshot names the main thread first, in the crash report's format, then every other thread")
    @MainActor
    func snapshotListsEveryThread() async throws {
        mulg_hang_watch_main_thread()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hang-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        // A busy thread, as the spinning game thread was.
        let spinning = Thread { var x = 0.0; while !Thread.current.isCancelled { x += 1 } ; _ = x }
        spinning.name = "spinner"
        spinning.start()
        defer { spinning.cancel() }
        // Never from the main thread: it would stop itself.
        await Task.detached {
            let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            mulg_hang_snapshot(fd)
            close(fd)
        }.value
        let report = try String(contentsOf: file, encoding: .utf8)
        let lines = report.components(separatedBy: "\n")
        #expect(lines.first?.hasPrefix("Main thread: ") == true)
        #expect(lines.contains("Backtrace of the hung main thread"))
        #expect(lines.contains { $0.hasPrefix("0  0x") })
        #expect(lines.contains { $0.hasPrefix("Images in the backtrace") })
        #expect(lines.contains { $0.hasPrefix("Thread ") && $0.contains("\"spinner\": running, CPU ") })
        // Nothing of the runtime's own code is on the main thread here, so nothing is blamed.
        #expect(DiagnosticsModule.blamedModule(report: report, runtimeUUID: "NONE",
                                               thread: "Backtrace of the hung main thread") { _ in nil } == nil)
    }

    @Test("The debugger hears of a main-thread stall and of its end from the shared watcher")
    @MainActor
    func stallsReachTheDebugger() async throws {
        let watchdog = HangWatchdog()
        let events = Mutex<[String]>([])
        watchdog.observeStalls { stall in
            events.withLock {
                switch stall {
                case .began: $0.append("began")
                case .ended(let seconds): $0.append(seconds >= HangWatchdog.stallThreshold ? "ended" : "early")
                }
            }
        }
        defer { watchdog.observeStalls(nil) }
        // Let the watcher see the main queue run once, then stall it.
        try await Task.sleep(for: .milliseconds(1200))
        usleep(useconds_t((HangWatchdog.stallThreshold + 1) * 1_000_000))  // blocks the main thread
        for _ in 0..<40 where events.withLock({ $0.count < 2 }) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(events.withLock { $0 } == ["began", "ended"])
    }

    @Test("Module notes join the crash and freeze report text, and leave it again")
    @MainActor
    func notesReachTheReports() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("context-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        let wasActive = DiagnosticsModule.crashReporterActive
        DiagnosticsModule.crashReporterActive = true
        defer {
            DiagnosticsModule.noteForCrashReports(DiagnosticNote(module: .controls, text: ""))
            DiagnosticsModule.crashReporterActive = wasActive
        }
        func context() throws -> String {
            let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            mulg_crash_write_context(fd)
            close(fd)
            return try String(contentsOf: file, encoding: .utf8)
        }
        DiagnosticsModule.setCrashContext("Stage: test")
        DiagnosticsModule.noteForCrashReports(DiagnosticNote(module: .controls, text: "  held inputs 2"))
        let with = try context()
        #expect(with.hasPrefix("Stage: test\ncontrols:\n  held inputs 2\n"))
        DiagnosticsModule.noteForCrashReports(DiagnosticNote(module: .controls, text: ""))
        #expect(try !context().contains("held inputs"))
    }

    @Test("Recovery reads crashes and unrecovered freezes, newest first by time, each once")
    @MainActor
    func recoveryReadsUnrecoveredFreezes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = ContainerPaths(home: home), id = "hang.recovery"
        let directory = paths.diagnosticsDirectory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["Crash-1759000100.txt", "Hang-1759000200.txt", "Hang-1759000300-recovered.txt"] {
            try Data("Mulg report\n".utf8).write(to: directory.appendingPathComponent(name))
        }
        var settings = GameSettings(bundleIdentifier: id)
        settings.mulg.diagnostics.crashReports = true // Off for new games.
        let first = DiagnosticsModule.lastCrash(settings: settings, paths: paths, bundleIdentifier: id)
        #expect(first?.report == "Hang-1759000200.txt")
        #expect(first?.hang == true)
        #expect(first?.module == nil)
        #expect(DiagnosticsModule.lastCrash(settings: settings, paths: paths, bundleIdentifier: id) == nil)

        #expect(DiagnosticsModule.isRecoveryReport("Crash-1.txt"))
        #expect(DiagnosticsModule.isRecoveryReport("Hang-2.txt"))
        #expect(!DiagnosticsModule.isRecoveryReport("Hang-2-recovered.txt"))
        #expect(!DiagnosticsModule.isRecoveryReport("debug.log"))
        #expect(DiagnosticsModule.reportTime("Hang-1759000300-recovered.txt") == 1_759_000_300)
    }

    @Test("A freeze inside the runtime's own code blames that module, from the main thread only")
    @MainActor
    func blamesTheMainThread() {
        let report = """
            Main thread: waiting, CPU 0%
            Backtrace of the hung main thread
            0  0x19000a000  libsystem_kernel.dylib + 0xa000
            1  0x104a3f10c  MulgRuntime + 0x1310c

            Images in the backtrace (load address, UUID, path)
            0x190000000  AAAA  /usr/lib/system/libsystem_kernel.dylib
            0x104a2c000  BBBB  /Users/me/Library/Frameworks/MulgRuntime.framework/MulgRuntime
            """
        #expect(DiagnosticsModule.blamedModule(report: report, runtimeUUID: "BBBB",
                                               thread: "Backtrace of the hung main thread") { _ in "$s11MulgDisplay3fooyyF" } == .display)
        // The crash parser does not mistake a freeze report for a crash.
        #expect(DiagnosticsModule.blamedModule(report: report, runtimeUUID: "BBBB") { _ in "$s11MulgDisplay3fooyyF" } == nil)
    }
}
