import Foundation
import MulgContracts
@testable import MulgDiagnostics
import Testing

@Suite("Crash reports")
struct CrashReportsTests {
    @Test("Only the newest reports are kept, and other files are left alone")
    @MainActor
    func removesOldReports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = (0..<12).map { "Crash-17590000\($0 + 10).txt" } + ["startup.json"]
        for name in names {
            try Data().write(to: directory.appendingPathComponent(name))
        }

        DiagnosticsModule.removeOldCrashReports(in: directory)

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(left == Array(names.dropFirst(2)).sorted())
    }

    @Test("Symbols name their module; Apple's and unknown code name none")
    @MainActor
    func symbolsNameModules() {
        #expect(DiagnosticsModule.module(forSymbol: "$s11MulgDisplay0B6ModuleC7prepareyyF") == .display)
        #expect(DiagnosticsModule.module(forSymbol: "_$s17MulgGraphicsHooks3fooyyF") == .graphics)
        #expect(DiagnosticsModule.module(forSymbol: "mulg_identity_configure_cpu") == .identity)
        #expect(DiagnosticsModule.module(forSymbol: "mulg_scene_frame") == nil)
        #expect(DiagnosticsModule.module(forSymbol: "$sSa6appendyyxnF") == nil)
        #expect(DiagnosticsModule.module(forSymbol: "objc_msgSend") == nil)
    }

    @Test("The first frame outside Apple's libraries decides who crashed")
    @MainActor
    func blamesFirstNonSystemFrame() {
        let report = """
            Backtrace of the crashed thread
            0  0x19000a000  libsystem_kernel.dylib + 0xa000
            1  0x5
            2  0x104a3f10c  MulgRuntime + 0x1310c
            3  0x102000100  Game + 0x100

            Images in the backtrace (load address, UUID, path)
            0x190000000  AAAA  /usr/lib/system/libsystem_kernel.dylib
            0x104a2c000  BBBB  /Users/me/Library/Frameworks/MulgRuntime.framework/MulgRuntime
            0x102000000  CCCC  /Users/me/Library/Containers/game/Game Folder/Game
            """
        var asked: UInt64?
        let blamed = DiagnosticsModule.blamedModule(report: report, runtimeUUID: "BBBB") { offset in
            asked = offset
            return "$s12MulgControls3fooyyF"
        }
        #expect(blamed == .controls)
        #expect(asked == 0x1310b)  // the call, one byte before the return address
        // Another build of the runtime: its offsets mean nothing here.
        #expect(DiagnosticsModule.blamedModule(report: report, runtimeUUID: "DDDD") { _ in "$s12MulgControls3fooyyF" } == nil)
        // The game crashed first.
        let game = report.replacingOccurrences(of: "2  0x104a3f10c  MulgRuntime + 0x1310c\n", with: "")
        #expect(DiagnosticsModule.blamedModule(report: game, runtimeUUID: "BBBB") { _ in "$s12MulgControls3fooyyF" } == nil)
    }
}
