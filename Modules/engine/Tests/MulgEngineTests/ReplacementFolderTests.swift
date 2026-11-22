import Foundation
import MulgEngineHooks
import Testing

@Suite("Replacement folders")
struct ReplacementFolderTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Only old, empty fallback folders are removed")
    func removesStaleEmptyFolders() throws {
        let files = FileManager.default, parent = try folder()
        defer { try? files.removeItem(at: parent) }
        let old = parent.appendingPathComponent(".mulg-replacement-old")
        let busy = parent.appendingPathComponent(".mulg-replacement-busy")
        let fresh = parent.appendingPathComponent(".mulg-replacement-fresh")
        let other = parent.appendingPathComponent("Saves")
        for url in [old, busy, fresh, other] { try files.createDirectory(at: url, withIntermediateDirectories: false) }
        try Data("x".utf8).write(to: busy.appendingPathComponent("file"))
        let hourAgo = Date(timeIntervalSinceNow: -3600)
        for url in [old, busy, other] { try files.setAttributes([.creationDate: hourAgo], ofItemAtPath: url.path) }

        mulg_engine_remove_stale_replacements(files, parent)

        #expect(!files.fileExists(atPath: old.path))
        #expect(files.fileExists(atPath: busy.path))
        #expect(files.fileExists(atPath: fresh.path))
        #expect(files.fileExists(atPath: other.path))
    }

    /// Saves to the Mac's disk must not get a temporary folder on the moved-data volume (a new install links the
    /// container's tmp there: cross-device rename, Endfield 2026-10-17); Mulg's own folder never gets one beside it.
    @Test("Replacement folders use the container's caches on the same volume, else the destination's folder")
    func replacementBase() throws {
        let parent = try folder(), caches = try folder()
        defer { try? FileManager.default.removeItem(at: parent); try? FileManager.default.removeItem(at: caches) }
        #expect(mulg_engine_replacement_base(parent, [caches]) == caches)
        #expect(mulg_engine_replacement_base(parent, nil) == parent)
        #expect(mulg_engine_replacement_base(parent, [caches.appendingPathComponent("missing")]) == parent)
        // A linked first choice on another volume falls through to the next folder on the right one.
        #expect(mulg_engine_replacement_base(parent, [caches.appendingPathComponent("missing"), caches]) == caches)
        let other = URL(fileURLWithPath: "/Volumes").appendingPathComponent(
            (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes"))?.first { name in
                !mulg_engine_same_volume(URL(fileURLWithPath: "/Volumes/" + name), parent) } ?? "missing")
        #expect(mulg_engine_replacement_base(other, [caches]) == other)
    }

    @Test("Volume comparison accepts one volume and refuses a missing folder")
    func sameVolume() throws {
        let parent = try folder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let child = parent.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        #expect(mulg_engine_same_volume(child, parent))
        #expect(!mulg_engine_same_volume(nil, parent))
        #expect(!mulg_engine_same_volume(parent.appendingPathComponent("missing"), parent))
    }
}
