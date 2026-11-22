import Foundation
import MulgContracts
@testable import MulgDiagnostics
import MulgDiagnosticsHooks
import OSLog
import Testing

@Suite("Debugger")
struct DebuggerTests {
    @Test("Settings files without the debugger keys get the defaults (all off); the CPU category writes crash reports")
    func settingsDefaults() throws {
        var settings = try JSONDecoder().decode(DiagnosticsSettings.self, from: Data("{}".utf8))
        #expect(settings == DiagnosticsSettings())
        // New games start with no debugging at all (2026-10-09).
        #expect(!settings.debugger && !settings.debugCPU && !settings.debugGraphics && !settings.debugShaders && !settings.debugGameLog)
        #expect(!settings.crashReports && !settings.performanceOverlay && !settings.measureInputLatency && !settings.hudLogging)
        #expect(!settings.writesCrashReports)
        settings.debugger = true
        #expect(!settings.writesCrashReports)
        settings.debugCPU = true
        #expect(settings.writesCrashReports)
    }

    @Test("The last launch's log is kept, and the log stops at its size limit")
    func rotatesAndCaps() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent(Debugger.fileName)

        let first = try #require(Debugger(directory: directory, settings: DiagnosticsSettings(), limit: 200))
        first.log("test", "first launch")
        first.close()
        let second = try #require(Debugger(directory: directory, settings: DiagnosticsSettings(), limit: 200))
        for index in 0..<20 {
            second.log("test", "line \(index)")
        }
        second.close()

        let previous = try String(contentsOf: directory.appendingPathComponent(Debugger.previousFileName), encoding: .utf8)
        #expect(previous.contains("[test] first launch"))
        let log = try String(contentsOf: current, encoding: .utf8)
        #expect(!log.contains("first launch"))
        #expect(log.contains("[test] line 0\n"))
        #expect(log.contains("The log is full"))
        #expect(!log.contains("line 19"))
    }

    @Test("Parts switched off while the game runs stop; Mulg starts no Metal validation, so no restart is asked for")
    func switchesOff() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = DiagnosticsSettings()
        settings.debugger = true
        settings.debugCPU = false
        settings.debugGraphics = true
        settings.debugGameLog = true
        let debugger = try #require(Debugger(directory: directory, settings: settings))

        settings.debugCPU = true
        settings.debugGraphics = false
        #expect(!debugger.apply(settings, on: true))  // no Apple validation was started at launch
        #expect(!debugger.cpu && !debugger.graphics && debugger.gameLog && debugger.running)
        debugger.apply(settings, on: false)
        #expect(!debugger.running)
        debugger.log("test", "after the stop")
        let log = try String(contentsOf: directory.appendingPathComponent(Debugger.fileName), encoding: .utf8)
        #expect(log.contains("[stop] Graphics switched off"))
        #expect(log.contains("[stop] Game log switched off"))
        #expect(!log.contains("CPU and crashes"))
        #expect(log.contains("[stop] The debugger is off"))
        #expect(!log.contains("after the stop"))
    }
}

@Suite("Debugger console pipe")
struct DebuggerConsolePipeTests {
    /// The runtime starts inside a load-time constructor: a blocked stderr write would freeze the game
    /// at launch (build 871). A full pipe must refuse the write instead of waiting for the reader.
    @Test func fullPipeNeverBlocksTheWriter() {
        var ends: [Int32] = [0, 0]
        #expect(mulg_debug_console_pipe(&ends) == 0)
        defer { close(ends[0]); close(ends[1]) }
        let chunk = [UInt8](repeating: 0x41, count: 4096)
        var refused = false
        for _ in 0..<1024 where !refused {  // far more than any pipe buffer
            let written = chunk.withUnsafeBytes { write(ends[1], $0.baseAddress, $0.count) }
            refused = written < 0 && errno == EAGAIN
        }
        #expect(refused)
        #expect(fcntl(ends[0], F_GETFD) & FD_CLOEXEC != 0 && fcntl(ends[1], F_GETFD) & FD_CLOEXEC != 0)
    }
}

@Suite("Game log filter")
struct ProcessLogFilterTests {
    @Test("System chatter is dropped by the log store; its errors and other lines stay")
    func dropsChatter() async throws {
        let start = Date()
        let marker = UUID().uuidString
        try await Task.sleep(for: .milliseconds(50))
        Logger(subsystem: "com.apple.network", category: "test").log("chatter \(marker, privacy: .public)")
        Logger(subsystem: "com.apple.network", category: "test").error("failure \(marker, privacy: .public)")
        Logger(subsystem: "com.apple.UIKit", category: "EventDispatch").log("event \(marker, privacy: .public)")
        Logger(subsystem: "io.mulg.test", category: "game").log("game \(marker, privacy: .public)")
        try await Task.sleep(for: .milliseconds(300))
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let kept = try store.getEntries(at: store.position(date: start), matching: Debugger.processLogFilter)
            .compactMap { ($0 as? OSLogEntryLog)?.composedMessage }.filter { $0.hasSuffix(marker) }
        #expect(Set(kept) == ["failure \(marker)", "game \(marker)"])
    }
}
