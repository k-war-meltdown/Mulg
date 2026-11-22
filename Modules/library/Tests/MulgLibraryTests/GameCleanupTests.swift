import Foundation
import Testing
import MulgContracts
@testable import MulgLibrary

@Suite("Game cleanup ownership")
struct GameCleanupTests {
    @Test func cachePathsBelongOnlyToTheExactGame() throws {
        let paths = ContainerPaths(home: URL(fileURLWithPath: "/tmp/mulg-cleanup-home"))
        let items = try GameCleanup.cacheItems(for: "com.example.game", paths: paths)
        #expect(items.count == 12)
        #expect(items.contains { $0.path.hasSuffix("Library/WebKit/com.example.game") })
        #expect(items.contains { $0.lastPathComponent == "com.example.game.savedState" })
        #expect(items.contains { $0.lastPathComponent == "com.example.game.binarycookies" })
        #expect(!items.contains { $0.lastPathComponent == "com.example.game2" })
        let pruned = try GameCleanup.pruneItems(for: "com.example.game", paths: paths)
        #expect(pruned.contains(paths.keymapDirectory(for: "com.example.game")))
        #expect(pruned.contains(paths.settingsFile(for: "com.example.game")))
        #expect(pruned.contains { $0.lastPathComponent == "com.example.game.db-wal" })
        #expect(pruned.allSatisfy { !$0.lastPathComponent.hasPrefix("com.example.game2") })
        #expect(throws: GameSessionLease.Failure.invalidIdentifier) { try GameCleanup.cacheItems(for: "..", paths: paths) }
    }

    @Test func runningLeaseBlocksCleanupAndAllCredentialFormatsAreRemovedWhenStopped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mulg-cleanup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root), id = "com.example.game"
        try FileManager.default.createDirectory(at: paths.mulgChainDirectory, withIntermediateDirectories: true)
        let names = [id, id + ".mulgVault", id + ".db", id + ".db-wal", id + ".db-shm", id + "2.db"]
        for name in names { try Data("credential".utf8).write(to: paths.mulgChainDirectory.appendingPathComponent(name)) }
        let lease = try GameSessionLease(bundleIdentifier: id, paths: paths)
        #expect(throws: GameSessionLease.Failure.busy) { try GameCleanup.removeCredentials(for: id, paths: paths) }
        #expect(throws: GameSessionLease.Failure.busy) { try GameCleanup.trashCaches(for: id, paths: paths) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.mulgChainDirectory.path).count == names.count)
        #expect(throws: GameSessionLease.Failure.invalidIdentifier) {
            try GameCleanup.removeCredentials(for: id + "2", paths: paths, sessionLease: lease)
        }
        try GameCleanup.removeCredentials(for: id, paths: paths, sessionLease: lease)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.mulgChainDirectory.path) == [id + "2.db"])
    }
}
