import Foundation
@testable import MulgContracts
@testable import MulgKeymaps
import Testing

@Suite("Control profiles", .serialized)
struct KeymapProfileTests {
    let store: KeymapStore

    init() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
        store = KeymapStore(folder: folder, bundleIdentifier: "com.example.game")
    }

    private func button(_ key: Int, _ name: String) -> KeymappingData {
        var map = KeymappingData(bundleIdentifier: "com.example.game")
        map.buttonModels = [ButtonElement(keyCode: key, keyName: name, transform: KeyModelTransform(size: 5, xCoord: 0.5, yCoord: 0.5))]
        return map
    }

    @Test("Names become safe file names")
    func sanitizing() {
        #expect(KeymapStore.sanitizedProfileName("  My   controls ") == "My controls")
        #expect(KeymapStore.sanitizedProfileName("../etc/passwd") == "etc passwd")
        #expect(KeymapStore.sanitizedProfileName("a:b\\c") == "a b c")
        #expect(KeymapStore.sanitizedProfileName(".hidden") == "hidden")
        #expect(KeymapStore.sanitizedProfileName("   ") == nil)
        #expect(KeymapStore.sanitizedProfileName("\n\t") == nil)
        #expect(KeymapStore.sanitizedProfileName(String(repeating: "x", count: 100))?.count == 60)
        #expect(KeymapStore.sanitizedProfileName("Genshin (WASD) ★")  == "Genshin (WASD) ★")
    }

    @Test("A new profile never replaces an existing one, whatever the case")
    func newProfilesAreUnique() throws {
        defer { try? FileManager.default.removeItem(at: store.folder) }
        _ = store.loadDefault()
        let first = try store.createProfile(named: "Combat", keymap: button(8, "E")).get()
        let second = try store.createProfile(named: "combat", keymap: button(9, "F")).get()
        let third = try store.createProfile(named: "Combat", keymap: button(10, "G")).get()
        #expect(first.lastPathComponent == "Combat.plist")
        #expect(second.lastPathComponent == "combat 2.plist")
        #expect(third.lastPathComponent == "Combat 3.plist")
        #expect(try store.read(first).get().buttonModels.first?.keyName == "E")
        #expect(store.profileNames().suffix(3) == ["Combat", "combat 2", "Combat 3"])
    }

    @Test("Making a profile the default changes only the config")
    func defaultProfile() throws {
        defer { try? FileManager.default.removeItem(at: store.folder) }
        let original = store.loadDefault()
        let before = try Data(contentsOf: original.file)
        let created = try store.createProfile(named: "Mine", keymap: button(8, "E")).get()
        #expect(store.makeDefault(created) == nil)
        #expect(store.loadDefault().file.lastPathComponent == "Mine.plist")
        #expect(try Data(contentsOf: original.file) == before)  // the earlier profile is untouched
        #expect(store.makeDefault(created) == nil)               // asking again is a no-op
        let order = store.profileNames()
        #expect(order.filter { $0 == "Mine" }.count == 1)
    }

    @Test("A profile is backed up before it is overwritten, newest five kept per profile")
    func backups() throws {
        defer { try? FileManager.default.removeItem(at: store.folder) }
        _ = store.loadDefault()
        let file = try store.createProfile(named: "Star Rail", keymap: button(8, "E")).get()
        let other = try store.createProfile(named: "Star Rail (adaptive)", keymap: button(9, "F")).get()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<8 {
            #expect(store.backUp(file, keeping: 5, now: start.addingTimeInterval(Double(index))))
        }
        #expect(store.backUp(other, keeping: 5, now: start))
        let backups = try FileManager.default.contentsOfDirectory(atPath: store.folder.appendingPathComponent(".backups").path)
        #expect(backups.filter { $0.hasPrefix("Star Rail 2") }.count == 5)           // pruned to five
        #expect(backups.filter { $0.hasPrefix("Star Rail (adaptive) ") }.count == 1) // not counted with the other
        // Backups do not show up as profiles.
        #expect(!store.profileNames().contains { $0.contains("2023") })
        // The backup holds what the file held.
        let copy = store.folder.appendingPathComponent(".backups").appendingPathComponent(try #require(backups.first { $0.hasPrefix("Star Rail 2") }))
        #expect(try store.read(copy).get().buttonModels.first?.keyName == "E")
    }

    @Test("A profile that does not exist yet has nothing to back up")
    func noBackupForNewFile() {
        defer { try? FileManager.default.removeItem(at: store.folder) }
        #expect(store.backUp(store.keymapFile(named: "Nothing")))
        #expect(!FileManager.default.fileExists(atPath: store.folder.appendingPathComponent(".backups").path))
    }

    @Test("An unreadable config is reported, not overwritten")
    func unreadableConfig() throws {
        defer { try? FileManager.default.removeItem(at: store.folder) }
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: store.configFile)
        #expect(store.makeDefault(store.keymapFile(named: "x")) != nil)
        #expect(try Data(contentsOf: store.configFile) == Data("not a plist".utf8))
    }
}
