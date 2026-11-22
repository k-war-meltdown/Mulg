#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Testing

@Suite("Display rotation request ownership")
struct RotationRetryTests {
    @Test func newestRequestSupersedesAWindowRetry() throws {
        let module = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try String(contentsOf: module.appendingPathComponent("Sources/MulgDisplay/DisplayRotation.swift"), encoding: .utf8)
            .components(separatedBy: .newlines).filter { !$0.hasPrefix("import ") }.joined(separator: "\n")
            .replacingOccurrences(of: "#if canImport(UIKit) && !os(watchOS)", with: "#if true")
        let fixture = try String(contentsOf: module.appendingPathComponent("Tests/HookFixtures/RotationRetry.swift"), encoding: .utf8)
        let file = folder.appendingPathComponent("fixture.swift")
        // UIKit is a deterministic window/presenter stub; request ownership is the production body.
        try ("import Foundation\n" + source + fixture).write(to: file, atomically: true, encoding: .utf8)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", "-swift-version", "6", "-module-cache-path",
            folder.appendingPathComponent("cache").path, file.path]
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, Comment(rawValue: String(decoding: output, as: UTF8.self)))
    }
}
#endif
