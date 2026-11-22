#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Testing

@Suite("Independent shutdown deadline")
struct ShutdownWatchdogTests {
    @Test func blockedCallbacksExitAndCompletedShutdownCancelsDeadline() throws {
        let module = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("shutdown")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-swift-version", "6", "-parse-as-library",
            module.appendingPathComponent("Sources/MulgEngine/ShutdownWatchdog.swift").path,
            module.appendingPathComponent("Tests/HookFixtures/ShutdownDeadline.swift").path,
            "-o", executable.path]
        try compiler.run(); compiler.waitUntilExit()
        #expect(compiler.terminationStatus == 0)
        for phase in ["background", "disconnect", "terminate", "native", "completed"] {
            let child = Process()
            child.executableURL = executable
            child.arguments = [phase]
            let start = Date()
            try child.run()
            while child.isRunning && Date().timeIntervalSince(start) < 3 { Thread.sleep(forTimeInterval: 0.01) }
            if child.isRunning { child.terminate(); Issue.record("Shutdown deadline failed for \(phase)") }
            child.waitUntilExit()
            #expect(child.terminationStatus == (phase == "completed" ? 0 : 75))
            #expect(Date().timeIntervalSince(start) < 3)
        }
    }
}
#endif
