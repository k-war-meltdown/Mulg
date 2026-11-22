import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let fixtures = URL(fileURLWithPath: CommandLine.arguments[2])
let output = URL(fileURLWithPath: CommandLine.arguments[3])
let name = CommandLine.arguments[4]
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
func body(_ source: String, _ signature: String) throws -> String {
    guard let start = source.range(of: signature)?.lowerBound, let brace = source[start...].firstIndex(of: "{") else {
        throw NSError(domain: "Missing production symbol: " + signature, code: 1)
    }
    var cursor = brace, depth = 0
    repeat {
        if source[cursor] == "{" { depth += 1 }
        if source[cursor] == "}" { depth -= 1 }
        cursor = source.index(after: cursor)
    } while depth > 0
    return String(source[start..<cursor])
}
func methods(_ source: String, _ signatures: [String]) throws -> String {
    try signatures.map { try body(source, $0).replacingOccurrences(of: "private func", with: "func") }.joined(separator: "\n")
}
func stripImports(_ source: String) -> String {
    source.components(separatedBy: .newlines).filter { !$0.hasPrefix("import ") }.joined(separator: "\n")
}
let controls = "Modules/controls/Sources/MulgControls/"
let graphics = "Modules/graphics/Sources/MulgGraphics/"
let engine = "Modules/engine/Sources/MulgEngine/"
let native = ["FrameOwnership", "ShaderGuard"].contains(name)
var code = try String(contentsOf: fixtures.appendingPathComponent(name + (native ? ".m" : ".swift")), encoding: .utf8)
func replace(_ marker: String, _ value: String) { code = code.replacingOccurrences(of: "// __" + marker + "__", with: value) }
switch name {
case "FrameOwnership": replace("PRODUCTION", try read("Modules/engine/Sources/MulgEngineHooks/MulgSleepThrottle.m"))
case "ControllerReset":
    replace("PRODUCTION", try methods(read(controls + "ControllerInput.swift"), ["private func accepts(", "func changed(_ sample:", "private func releaseEverything() "]))
case "DeviceFanout":
    replace("PRODUCTION", try methods(read(controls + "VirtualController.swift"), ["private func setButton("])
        .replacingOccurrences(of: "#if canImport(UIKit) && targetEnvironment(macCatalyst)", with: "#if true"))
case "SwipeBounds": replace("PRODUCTION", "@MainActor\n" + (try body(read(controls + "Actions.swift"), "public final class SwipeAction")))
case "TouchCleanup":
    let injector = try body(read(controls + "TouchInjection.swift"), "public final class SystemTouchInjector")
    replace("PRODUCTION", try methods(injector, ["public func touch(_ id:", "public func cancel(_ id:"]))
case "LifecycleClose":
    let source = try read(engine + "GameLifecycle.swift")
    replace("STATE", try body(source, "public enum LifecycleState:"))
    replace("PRODUCTION", try methods(source, ["public func end()", "private func move(to target:", "private func performMove(to target:", "private static func state(of scene:"]))
    let start = source.range(of: "private extension LifecycleState.Step")!.lowerBound
    replace("STEPS", try body(String(source[start...]), "private extension LifecycleState.Step").replacingOccurrences(of: "private extension", with: "extension"))
case "GraphicsClose": replace("PRODUCTION", try methods(read(graphics + "GraphicsModule.swift"), ["func mainLayerChanged(to layer:"]))
case "AutomaticTarget": replace("PRODUCTION", try stripImports(read(graphics + "AutomaticMetalFX.swift")))
case "ShaderGuard":
    replace("PRODUCTION", try methods(read("Modules/graphics/Sources/MulgGraphicsHooks/MulgGraphicsHooks.m"), ["static void game_build_ended_once(", "static id __attribute__((ns_returns_retained)) mulg_render_pipeline(", "static void mulg_render_pipeline_async("]))
case "RecoveredUpscale":
    replace("PRODUCTION", try stripImports(read(graphics + "GraphicsInterceptor.swift")))
    let source = try read(graphics + "GraphicsModule.swift")
    replace("CHECK", source.contains("interceptor?.upscaleIsFailing(generation:")
        ? "interceptor.upscaleIsFailing(generation: generation)" : "interceptor.isCurrent(generation: generation)")
default: fatalError("Unknown regression")
}
if native {
    code = "#include <stdio.h>\n#include <stdlib.h>\n#define AUDIT_CHECK(...) do { if (!(__VA_ARGS__)) { fprintf(stderr, \"FAIL at line %d\\n\", __LINE__); exit(42); } } while (0)\n" + code.replacingOccurrences(of: "assert(", with: "AUDIT_CHECK(")
} else {
    code = "func auditCheck(_ condition: @autoclosure () -> Bool, _ message: String = \"Regression failed\") { if !condition() { print(\"FAIL: \" + message); exit(42) } }\n" + code.replacingOccurrences(of: "assert(", with: "auditCheck(")
}
let file = output.appendingPathComponent(name + (native ? ".m" : ".swift"))
try code.write(to: file, atomically: true, encoding: .utf8)
func run(_ args: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun"); process.arguments = args
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
if native {
    let binary = output.appendingPathComponent(name)
    let include = CommandLine.arguments.count > 5 ? CommandLine.arguments[5] : root.path
    let status = try run(["clang", "-fobjc-arc", "-fblocks", "-I", include + "/Modules/engine/Sources/MulgEngineHooks/include",
        file.path, "-framework", "Foundation", "-framework", "QuartzCore", "-framework", "Metal", "-o", binary.path])
    guard status == 0 else { exit(status) }
    let process = Process(); process.executableURL = binary; try process.run(); process.waitUntilExit(); exit(process.terminationStatus)
} else {
    exit(try run(["swift", "-swift-version", "6", "-module-cache-path", output.appendingPathComponent("cache").path, file.path]))
}
