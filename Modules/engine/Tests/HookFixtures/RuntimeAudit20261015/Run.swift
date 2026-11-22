import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let fixtures = URL(fileURLWithPath: CommandLine.arguments[2])
let output = URL(fileURLWithPath: CommandLine.arguments[3])
let name = CommandLine.arguments[4]
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
func stripped(_ source: String) -> String {
    source.components(separatedBy: .newlines).filter { !$0.hasPrefix("import ") }.joined(separator: "\n")
}
func body(_ source: String, _ signature: String) throws -> String {
    guard let start = source.range(of: signature)?.lowerBound, let brace = source[start...].firstIndex(of: "{") else {
        throw NSError(domain: "Missing production symbol " + signature, code: 1)
    }
    var cursor = brace, depth = 0
    repeat {
        if source[cursor] == "{" { depth += 1 }
        if source[cursor] == "}" { depth -= 1 }
        cursor = source.index(after: cursor)
    } while depth > 0
    return String(source[start..<cursor])
}
let controls = "Modules/controls/Sources/MulgControls/"
let engine = "Modules/engine/Sources/MulgEngineHooks/"
let native = ["Audio", "Priority", "Lifecycle", "Background"].contains(name)
var code: String
if name == "Background" {
    code = try read("Modules/engine/Tests/HookFixtures/BackgroundTracking.m")
    code = code.replacingOccurrences(of: "static BOOL recycleIdentifier;", with: "static BOOL recycleIdentifier, verifyEnding;")
    code = code.replacingOccurrences(of: "if (recycleIdentifier && task == 1) {", with:
        "if (verifyEnding) assert(mulg_engine_background_task_count() >= 1);\n    if (recycleIdentifier && task == 1) {")
    code = code.replacingOccurrences(of: "[self beginBackgroundTaskWithExpirationHandler:^{}];", with:
        "[self beginBackgroundTaskWithExpirationHandler:^{}];\n        if (verifyEnding) assert(mulg_engine_background_task_count() == 2);")
    code = code.replacingOccurrences(of: "recycleIdentifier = YES;", with: "verifyEnding = YES; recycleIdentifier = YES;")
    code = code.replacingOccurrences(of: "assert(mulg_engine_background_task_count() == 1); //", with: "verifyEnding = NO; assert(mulg_engine_background_task_count() == 1); //")
    code = code.replacingOccurrences(of: "\"../../Sources/MulgEngineHooks/MulgCompatHooks.m\"", with:
        "\"" + root.appendingPathComponent(engine + "MulgCompatHooks.m").path + "\"")
} else {
    code = try String(contentsOf: fixtures.appendingPathComponent(name + (native ? ".m" : ".swift")), encoding: .utf8)
}
func replace(_ marker: String, _ value: String) { code = code.replacingOccurrences(of: "// __" + marker + "__", with: value) }
switch name {
case "Gestures":
    replace("PRODUCTION", try stripped(read(controls + "PinchZoom.swift")) + "\n" + stripped(read(controls + "TrackpadGestures.swift")))
case "Tasks":
    let ticker = try read(controls + "FrameTicker.swift")
    let waiters = try body(read(controls + "TouchInjection.swift"), "final class TouchBeginWaiters")
    replace("PRODUCTION", (stripped(ticker) + "\n@MainActor\n" + waiters)
        .replacingOccurrences(of: "Task.sleep(for: timeout)", with: "WaitClock.sleep(timeout)"))
case "Virtual":
    let source = try read(controls + "VirtualController.swift")
    var methods = ""
    for method in ["public func key(code:", "public func isActive(", "private func applyHeldInputs()", "public func set(_ element:", "public func releaseAll()"] {
        methods += try body(source, method).replacingOccurrences(of: "private func", with: "func") + "\n"
    }
    replace("PRODUCTION", methods)
case "Raw": replace("PRODUCTION", try body(read(controls + "InputRouter.swift"), "final class RawMouse"))
case "Toggle": replace("PRODUCTION", try body(read(controls + "Actions.swift"), "func update(pressed: Bool)"))
case "Counter":
    let source = try read("Modules/display/Sources/MulgDisplay/DisplayModule.swift")
    if source.contains("static func bytesWritten(since") {
        replace("PRODUCTION", try body(source, "static func bytesWritten(since"))
    } else {
        // Exercise the old production subtraction against the same reset cases.
        let start = source.range(of: "let busy = Self.isBusy(bytesWritten: ")!.upperBound
        let line = source[start...].prefix { $0 != "\n" }.dropLast()
        let expression = line.replacingOccurrences(of: "self.lastBytesWritten", with: "previous")
            .replacingOccurrences(of: "written", with: "current")
        replace("PRODUCTION", "static func bytesWritten(since previous: inout UInt64, current: UInt64) -> UInt64? { let delta = " + expression + "; previous = current; return delta }")
    }
case "Audio": replace("PRODUCTION", "#include \"" + root.appendingPathComponent(engine + "MulgAudioMute.m").path + "\"")
case "Priority": replace("PRODUCTION", "#include \"" + root.appendingPathComponent(engine + "MulgThreadPriority.m").path + "\"")
case "Lifecycle":
    var source = try read(engine + "MulgLifecycleNotifications.m")
    source = try source.replacingOccurrences(of: body(source, "static BOOL lifecycle_name("), with: "static BOOL lifecycle_name(NSString *name) { return YES; }")
    let production = output.appendingPathComponent("LifecycleProduction.m")
    try source.write(to: production, atomically: true, encoding: .utf8)
    replace("PRODUCTION", "#include \"" + production.path + "\"")
case "Background": break
default: fatalError("Unknown regression")
}
let file = output.appendingPathComponent(name + (native ? ".m" : ".swift"))
// Failed regressions return a bounded status without producing system crash reports.
if native {
    code = "#include <stdio.h>\n#include <stdlib.h>\n#define MULG_AUDIT_CHECK(...) do { if (!(__VA_ARGS__)) { fprintf(stderr, \"FAIL at line %d\\n\", __LINE__); exit(42); } } while (0)\n"
        + code.replacingOccurrences(of: "assert(", with: "MULG_AUDIT_CHECK(")
} else {
    code = "func auditCheck(_ condition: @autoclosure () -> Bool, _ message: String = \"Regression failed\") { if !condition() { print(\"FAIL: \" + message); exit(42) } }\n"
        + code.replacingOccurrences(of: "assert(", with: "auditCheck(")
}
try code.write(to: file, atomically: true, encoding: .utf8)
func run(_ args: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = args
    try process.run(); process.waitUntilExit()
    return process.terminationStatus
}
if native {
    let binary = output.appendingPathComponent(name)
    let result = try run(["clang", "-fobjc-arc", "-fblocks", "-Wno-cast-of-sel-type",
        "-I", root.appendingPathComponent(engine + "include").path,
        "-I", root.appendingPathComponent("Modules/engine/Tests/HookFixtures").path,
        file.path, "-framework", "Foundation", "-framework", "AudioToolbox", "-framework", "CoreAudio", "-o", binary.path])
    guard result == 0 else { exit(result) }
    let process = Process(); process.executableURL = binary
    try process.run(); process.waitUntilExit(); exit(process.terminationStatus)
} else {
    exit(try run(["swift", "-swift-version", "6", "-module-cache-path", output.appendingPathComponent("cache").path, file.path]))
}
