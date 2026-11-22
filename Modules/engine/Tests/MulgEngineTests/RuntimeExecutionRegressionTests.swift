#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Testing

/// Executes production bodies with deterministic scheduling or native API stand-ins.
/// The fixtures do not launch a game or build the app, package, runtime or bridge.
@Suite("Game execution regressions")
struct RuntimeExecutionRegressionTests {
    @Test(arguments: [
        ("Hold", "inward"), ("Hold", "retarget"), ("Calibration", "default"),
        ("Lifecycle", "default"), ("ControllerAliases", "default"), ("Priority", "default"),
        ("Motion", "ownership"), ("Motion", "capability"),
        ("FrameRate", "request"), ("FrameRate", "throttle"), ("FrameRate", "mtk"),
        ("TouchRelease", "default")
    ])
    func productionRegression(_ fixture: String, _ scenario: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appendingPathComponent("Modules/engine/Tests/HookFixtures/RuntimeReliability20261015")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", "-module-cache-path", output.appendingPathComponent("driver-cache").path,
            fixtures.appendingPathComponent("Run.swift").path, root.path, fixtures.path, output.path, fixture, scenario]
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, Comment(rawValue: String(decoding: data, as: UTF8.self)))
    }
}
#endif
