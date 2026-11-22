#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Testing

@Suite("Relocated game storage capacity")
struct StorageCapacityTests {
    @Test(arguments: ["macos27.0", "ios27.0-macabi"])
    func queriesRealDestinationAndPreservesErrorsAndNativeCallers(platform: String) throws {
        let module = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let hooks = module.appendingPathComponent("Sources/MulgEngineHooks")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        func run(_ file: String, _ arguments: [String]) throws -> (Int32, String) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: file); process.arguments = arguments
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let bytes = try pipe.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
        }
        let sdk = try run("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"])
        try #require(sdk.0 == 0, Comment(rawValue: sdk.1))
        let build = try run("/usr/bin/xcrun", ["clang", "-target", "arm64-apple-" + platform,
            "-isysroot", sdk.1.trimmingCharacters(in: .whitespacesAndNewlines),
            "-fobjc-arc", "-Wall", "-Werror", "-Wno-cast-of-sel-type", "-I", hooks.appendingPathComponent("include").path,
            module.appendingPathComponent("Tests/HookFixtures/StorageCapacity.m").path,
            hooks.appendingPathComponent("MulgGameDataHooks.m").path,
            hooks.appendingPathComponent("MulgFileHooks.m").path,
            hooks.appendingPathComponent("MulgSwizzle.m").path,
            "-framework", "Foundation", "-o", output.path])
        try #require(build.0 == 0, Comment(rawValue: build.1))
        let result = try run(output.path, [])
        #expect(result.0 == 0, Comment(rawValue: result.1))
    }
}
#endif
