#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Testing

/// Endfield 1.6.3 crashed while warming up its shaders after an update (corrupt lock in the driver's
/// program cache, 2026-10-17). Mulg's optional archive adds compile through the same driver, so they
/// wait until the game's own pipeline builds are quiet. Runs the production hooks in a fixture.
@Suite("Shader capture waits for quiet game compilation")
struct ShaderCompileQuietRegressionTests {
    @Test func archiveAddsNeverOverlapGameBuilds() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let binary = out.appendingPathComponent("shader-compile-quiet")
        func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let paths = ["Modules/graphics/Tests/HookFixtures/ShaderCompileQuiet.m",
                     "Modules/graphics/Sources/MulgGraphicsHooks/MulgForcedResolution.m",
                     "Modules/engine/Sources/MulgEngineHooks/MulgMetalDeviceHooks.m",
                     "Modules/graphics/Sources/MulgGraphicsHooks/MulgRenderSurface.m",
                     "Modules/engine/Sources/MulgEngineHooks/MulgSwizzle.m"]
        let args = ["clang", "-fobjc-arc", "-fblocks", "-Wno-incompatible-pointer-types",
                    "-I", root.appendingPathComponent("Modules/engine/Sources/MulgEngineHooks/include").path,
                    "-I", root.appendingPathComponent("Modules/graphics/Sources/MulgGraphicsHooks/include").path]
            + paths.map { root.appendingPathComponent($0).path }
            + ["-framework", "Foundation", "-framework", "Metal", "-framework", "QuartzCore",
               "-framework", "CoreGraphics", "-o", binary.path]
        let compiled = try run("/usr/bin/xcrun", args)
        try #require(compiled.0 == 0, Comment(rawValue: compiled.1))
        let result = try run(binary.path, [])
        #expect(result.0 == 0, Comment(rawValue: result.1))
    }
}
#endif
