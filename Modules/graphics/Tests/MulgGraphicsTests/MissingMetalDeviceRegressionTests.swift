#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Testing

@Suite("Generic missing Metal device recovery")
struct MissingMetalDeviceRegressionTests {
    @Test func productionLayerRecoveryPreservesNativeOwnership() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let binary = out.appendingPathComponent("missing-device")
        func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let paths = ["Modules/graphics/Tests/HookFixtures/MissingMetalDevice.m",
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
        for scenario in ["recover", "native", "multiple", "none", "system", "concurrent-native", "teardown", "layers", "parallel"] {
            let result = try run(binary.path, [scenario])
            #expect(result.0 == 0, Comment(rawValue: scenario + ": " + result.1))
        }
    }
}
#endif