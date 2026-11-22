import AppKit
import Foundation
import Testing
import MulgContracts
@testable import MulgLibrary

@Suite("Game run state")
@MainActor
struct GameRunStateTests {
    /// Finder always runs and was launched long before the test.
    let finder = "com.apple.finder"

    private func marker(stage: String, updated: Date, in paths: ContainerPaths) throws {
        let file = paths.safeModeMarker(for: finder)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record: [String: Any] = ["stage": stage, "updated": updated.timeIntervalSinceReferenceDate]
        try JSONSerialization.data(withJSONObject: record).write(to: file)
    }

    @Test func closingStageAfterLaunchShowsClosing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root)
        #expect(GameWatcher.runStates(paths: paths)[finder] == .running)
        try marker(stage: "closing", updated: .now, in: paths)
        #expect(GameWatcher.runStates(paths: paths)[finder] == .closing)
        // A closing record older than the running process is from an earlier session.
        try marker(stage: "closing", updated: .distantPast, in: paths)
        #expect(GameWatcher.runStates(paths: paths)[finder] == .running)
        try marker(stage: "running", updated: .now, in: paths)
        #expect(GameWatcher.runStates(paths: paths)[finder] == .running)
    }

    @Test func exitedProcessIsLeftOut() throws {
        let app = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: finder).first)
        #expect(GameWatcher.runStates(exitedProcess: app.processIdentifier)[finder] == nil)
        #expect(GameWatcher.isRunning(finder))
        #expect(!GameWatcher.isRunning("io.mulg.not-installed-\(UUID().uuidString)"))
    }
}
