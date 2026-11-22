#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Testing

@Suite("Crash image snapshot")
struct CrashSignalTests {
    private func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    @Test func capturesLateLoadedImagesAndRestoresThePreviousHandler() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hooks = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MulgDiagnosticsHooks")
        let main = folder.appendingPathComponent("fixture.m")
        let plugin = folder.appendingPathComponent("plugin.c")
        let executable = folder.appendingPathComponent("fixture")
        let library = folder.appendingPathComponent("SnapshotPlugin.dylib")
        try Data("""
            #include "MulgDiagnosticsHooks.h"
            #include <dlfcn.h>
            #include <signal.h>
            #include <unistd.h>
            static void previous(int value) { (void)value; _exit(77); }
            int main(int argc, char **argv) {
                if (argc != 3) return 3;
                signal(SIGABRT, previous);
                mulg_crash_install(argv[1]);
                mulg_crash_set_context("snapshot-fixture-context");
                if (!dlopen(argv[2], RTLD_NOW)) return 4;
                raise(SIGABRT);
                return 5;
            }
            """.utf8).write(to: main)
        try Data("""
            #include <stdint.h>
            static const char message[] = "late-loaded-image-fixture";
            __attribute__((used, section("__DATA,__crash_info")))
            static const struct { uint64_t version, message, signature, backtrace, message2; } annotation = {
                1, (uintptr_t)message, 0, 0, 0
            };
            void snapshot_plugin_fixture(void) {}
            """.utf8).write(to: plugin)
        let builds = [
            ["clang", "-fobjc-arc", "-fblocks", "-I", hooks.appendingPathComponent("include").path,
             main.path, hooks.appendingPathComponent("MulgCrashReporter.m").path, "-framework", "Foundation", "-o", executable.path],
            ["clang", "-dynamiclib", plugin.path, "-o", library.path]
        ]
        for arguments in builds {
            let (status, output) = try run("/usr/bin/xcrun", arguments)
            try #require(status == 0, Comment(rawValue: output))
        }
        // The deliberate fault runs only in the child; its previous handler exits without a crash dialog.
        let (status, _) = try run(executable.path, [folder.path, library.path])
        #expect(status == 77)
        let report = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("Crash-") })
        let text = try String(contentsOf: report, encoding: .utf8)
        #expect(text.contains("SIGABRT"))
        #expect(text.contains("SnapshotPlugin.dylib: late-loaded-image-fixture"))
        #expect(text.contains("snapshot-fixture-context"))
    }
}
#endif
