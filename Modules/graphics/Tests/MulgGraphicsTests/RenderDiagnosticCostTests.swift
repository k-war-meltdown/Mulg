#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Testing

@Suite("Render-path regression checks")
struct RenderDiagnosticCostTests {
    @Test(arguments: ["RenderDiagnosticCost.m", "FrameSubmission.m", "PresentationBookkeeping.m"])
    func productionHooksKeepAccurateCountersAndFramePacing(_ fixture: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let binary = out.appendingPathComponent("render-diagnostic-cost")
        func run(_ executable: String, _ arguments: [String]) throws {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0, Comment(rawValue: String(decoding: data, as: UTF8.self)))
        }
        let paths = ["Modules/graphics/Tests/HookFixtures/" + fixture,
                     "Modules/graphics/Sources/MulgGraphicsHooks/MulgForcedResolution.m",
                     "Modules/engine/Sources/MulgEngineHooks/MulgMetalDeviceHooks.m",
                     "Modules/graphics/Sources/MulgGraphicsHooks/MulgRenderSurface.m",
                     "Modules/engine/Sources/MulgEngineHooks/MulgSwizzle.m"]
        try run("/usr/bin/xcrun", ["clang", "-fobjc-arc", "-fblocks", "-Wno-incompatible-pointer-types",
            "-I", root.appendingPathComponent("Modules/engine/Sources/MulgEngineHooks/include").path,
            "-I", root.appendingPathComponent("Modules/graphics/Sources/MulgGraphicsHooks/include").path]
            + paths.map { root.appendingPathComponent($0).path }
            + ["-framework", "Foundation", "-framework", "Metal", "-framework", "QuartzCore",
               "-framework", "CoreGraphics", "-o", binary.path])
        if fixture == "FrameSubmission.m" {
            try run(binary.path, ["validation"])
            try run(binary.path, ["config"])
            try run(binary.path, ["lookup"])
            try run(binary.path, ["order"])
            try run(binary.path, ["reuse"])
            try run(binary.path, ["driver"])
            try run(binary.path, ["timing"])
        } else {
            try run(binary.path, [])
        }
    }
}
#endif
