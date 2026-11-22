import Foundation
import Testing
@testable import MulgContracts

@Suite("Early startup failure evidence")
struct RuntimeStartupFailureTests {
    @Test func acceptsOnlyTheProcessAndLaunchThatWroteTheFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root)
        let start = Date().addingTimeInterval(-1)
        let report = RuntimeStartupFailure(processIdentifier: 123, bundleIdentifier: "game.example",
                                           message: "Native bundle unavailable")
        try report.save(paths: paths)
        #expect(RuntimeStartupFailure.current(paths: paths, bundleIdentifier: "game.example",
            processIdentifier: 123, startedAt: start)?.message == report.message)
        #expect(RuntimeStartupFailure.current(paths: paths, bundleIdentifier: "game.example",
            processIdentifier: 124, startedAt: start) == nil)
        #expect(RuntimeStartupFailure.current(paths: paths, bundleIdentifier: "another.game",
            processIdentifier: 123, startedAt: start) == nil)
        #expect(RuntimeStartupFailure.current(paths: paths, bundleIdentifier: "game.example",
            processIdentifier: 123, startedAt: report.recordedAt.addingTimeInterval(1)) == nil)
    }
}
