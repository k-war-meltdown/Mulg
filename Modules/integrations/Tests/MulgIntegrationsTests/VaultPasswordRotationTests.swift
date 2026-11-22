#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Testing
import MulgVault

@Suite("Recoverable vault password rotation")
struct VaultPasswordRotationTests {
    enum Failed: Error { case keychain }

    @Test func keyFailureRetainsPlaintextAndPreparedCiphertextUntilRecovery() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        for id in ["game.a", "game.b"] { try Data("old".utf8).write(to: folder.appendingPathComponent(id + ".db")) }
        try VaultPasswordRotation.prepare(in: folder, identifiers: ["game.a", "game.b"]) { id, target in
            try Data("new-\(id)".utf8).write(to: target)
        }
        #expect(throws: Failed.keychain) {
            try VaultPasswordRotation.recover(in: folder) { throw Failed.keychain }
        }
        #expect(VaultPasswordRotation.hasPending(in: folder))
        #expect(try Data(contentsOf: folder.appendingPathComponent("game.a.db")) == Data("old".utf8))
        var commits = 0
        try VaultPasswordRotation.recover(in: folder) {
            let installed = try Data(contentsOf: folder.appendingPathComponent("game.b.mulgVault"))
            #expect(installed == Data("new-game.b".utf8))
            commits += 1
        }
        #expect(commits == 1 && !VaultPasswordRotation.hasPending(in: folder))
        #expect(!files.fileExists(atPath: folder.appendingPathComponent("game.a.db").path))
        try VaultPasswordRotation.recover(in: folder) { Issue.record("completed rotation must not commit again") }
    }

    @Test func preparationFailureNeverChangesAnExistingVault() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let existing = folder.appendingPathComponent("game.a.mulgVault")
        try Data("old-encrypted".utf8).write(to: existing)
        #expect(throws: Failed.keychain) {
            try VaultPasswordRotation.prepare(in: folder, identifiers: ["game.a", "game.b"]) { id, target in
                if id == "game.b" { throw Failed.keychain }
                try Data("new-encrypted".utf8).write(to: target)
            }
        }
        #expect(try Data(contentsOf: existing) == Data("old-encrypted".utf8))
        #expect(!VaultPasswordRotation.hasPending(in: folder))
    }
}
#endif
