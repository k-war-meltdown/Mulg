#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Testing

@Suite("Runtime task and Core Motion regressions")
struct RuntimeTaskRegressionTests {
    private var module: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
    private func method(_ source: String, signature: String) throws -> String {
        let start = try #require(source.range(of: signature)?.lowerBound)
        var cursor = try #require(source[start...].firstIndex(of: "{")), depth = 0
        repeat {
            if source[cursor] == "{" { depth += 1 }
            if source[cursor] == "}" { depth -= 1 }
            cursor = source.index(after: cursor)
        } while depth != 0
        return String(source[start..<cursor])
    }
    private func swiftFixture(_ name: String, production: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let template = try String(contentsOf: module.appendingPathComponent("Tests/HookFixtures/\(name).swift"), encoding: .utf8)
        let file = folder.appendingPathComponent("fixture.swift")
        try template.replacingOccurrences(of: "// __PRODUCTION__", with: production)
            .write(to: file, atomically: true, encoding: .utf8)
        let result = try run("/usr/bin/xcrun", ["swift", "-swift-version", "6", "-module-cache-path",
            folder.appendingPathComponent("cache").path, file.path])
        #expect(result.0 == 0, Comment(rawValue: result.1))
    }

    @Test func cancelledSwipeTimerCannotMutateTheNextContact() throws {
        let source = try String(contentsOf: module.appendingPathComponent("Sources/MulgControls/Actions.swift"), encoding: .utf8)
        let body = try method(source, signature: "public final class SwipeAction")
        // Control scheduling only; all lifecycle and counter logic is the production body.
        try swiftFixture("SwipeIdle", production: "@MainActor\n" + body.replacingOccurrences(
            of: "try? await Task.sleep(for: .milliseconds(100))", with: "await SwipeTestClock.wait()"))
    }

    @Test func unusableNativeConnectionCanRetryAndTransferHeldInput() throws {
        let source = try String(contentsOf: module.appendingPathComponent("Sources/MulgControls/VirtualController.swift"), encoding: .utf8)
        try swiftFixture("NativeConnection", production: method(source, signature: "public func connectNativeDevice()")
            .replacingOccurrences(of: "#if canImport(UIKit) && targetEnvironment(macCatalyst)", with: "#if true"))
    }

    @Test(arguments: ["copy", "relative"])
    func virtualAttitudeImplementsNativeOperations(_ operation: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try String(contentsOf: module.appendingPathComponent("Sources/MulgControlsHooks/MulgMotionHooks.m"), encoding: .utf8)
        let start = try #require(source.range(of: "@interface MulgAttitude")?.lowerBound)
        let end = try #require(source.range(of: "@interface MulgDeviceMotion")?.lowerBound)
        let cases = try String(contentsOf: module.appendingPathComponent("Tests/HookFixtures/VirtualAttitude.m"), encoding: .utf8)
        let fixture = folder.appendingPathComponent("fixture.m"), binary = folder.appendingPathComponent("fixture")
        try ("#import <CoreMotion/CoreMotion.h>\n#include <math.h>\n#include <assert.h>\n" + source[start..<end] + cases)
            .write(to: fixture, atomically: true, encoding: .utf8)
        let compiled = try run("/usr/bin/xcrun", ["clang", "-fobjc-arc", "-framework", "Foundation",
            "-framework", "CoreMotion", fixture.path, "-o", binary.path])
        try #require(compiled.0 == 0, Comment(rawValue: compiled.1))
        let result = try run(binary.path, [operation])
        #expect(result.0 == 0, Comment(rawValue: result.1))
    }
}
#endif
