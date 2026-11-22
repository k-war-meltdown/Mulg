import Foundation
import MulgContracts
@testable import MulgIntegrations
import Testing

/// The game's credential database key comes from its sealed file, never the macOS Keychain (2026-10-10).
@Suite("Sealed credential keys", .serialized, .enabled(if: SealedSecret.isAvailable))
struct SealedCredentialKeyTests {
    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mulg-key-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("com.example.game.key")
    }

    @Test("A new game gets a key that is sealed, kept and found again")
    func newKey() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var legacyReads = 0
        let key = try #require(IntegrationsModule.databaseKey(file: file, purpose: "p", create: true,
                                                              legacy: { legacyReads += 1; return nil }, removeLegacy: {}))
        #expect(key.count == 32)
        #expect(try SealedSecret.read(file, purpose: "p") == key)
        let again = IntegrationsModule.databaseKey(file: file, purpose: "p", create: false,
                                                   legacy: { legacyReads += 1; return nil }, removeLegacy: {})
        #expect(again == key)
        #expect(legacyReads == 1) // once the file exists, the old store is never asked again
    }

    @Test("An older Keychain key moves into the file, then the old item is removed")
    func migration() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let old = Data(repeating: 7, count: 32)
        var removed = false
        let key = IntegrationsModule.databaseKey(file: file, purpose: "p", create: false,
                                                 legacy: { old }, removeLegacy: { removed = true })
        #expect(key == old)
        #expect(removed)
        #expect(try SealedSecret.read(file, purpose: "p") == old)
    }

    @Test("An existing database never gets a new key, and an unreadable key file is never replaced")
    func neverDestructive() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(IntegrationsModule.databaseKey(file: file, purpose: "p", create: false, legacy: { nil }, removeLegacy: {}) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try Data("damaged".utf8).write(to: file)
        #expect(IntegrationsModule.databaseKey(file: file, purpose: "p", create: true, legacy: { nil }, removeLegacy: {}) == nil)
        #expect(try Data(contentsOf: file) == Data("damaged".utf8))
        // A key sealed for another game opens as nothing here.
        try SealedSecret.write(Data(repeating: 1, count: 32), to: file, purpose: "other")
        #expect(IntegrationsModule.databaseKey(file: file, purpose: "p", create: true, legacy: { nil }, removeLegacy: {}) == nil)
    }
}
