#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Testing

/// Execute the shared production paths with controlled native APIs and scheduling.
/// These fixtures do not launch or alter an installed game.
@Suite("Shared runtime cancellation and ownership", .serialized)
struct RuntimeAuditTests {
    @Test(arguments: ["Gestures", "Tasks", "Audio", "Priority", "Counter", "Virtual", "Raw", "Lifecycle", "Background", "Toggle"])
    func regression(_ name: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appendingPathComponent("Modules/engine/Tests/HookFixtures/RuntimeAudit20261015")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", "-module-cache-path", output.appendingPathComponent("driver-cache").path,
            fixtures.appendingPathComponent("Run.swift").path, root.path, fixtures.path, output.path, name]
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, Comment(rawValue: String(decoding: data, as: UTF8.self)))
    }
}
#endif
