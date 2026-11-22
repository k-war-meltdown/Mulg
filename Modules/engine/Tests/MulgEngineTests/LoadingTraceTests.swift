import Foundation
@testable import MulgEngine
import MulgEngineHooks
import Testing

@Suite("Learned read-ahead order")
struct LoadingTraceTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func bigFile(_ name: String, in root: URL) throws -> URL {
        let file = root.appendingPathComponent(name)
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(LoadingTrace.minimumSize))
        try handle.close()
        return file
    }

    @Test("Open big files under a root are listed; small ones and other folders are not")
    func listsOpenFiles() throws {
        let root = try makeRoot(), other = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        let big = try bigFile("data.blk", in: root), outside = try bigFile("data.blk", in: other)
        let small = root.appendingPathComponent("small.blk")
        try Data(count: 16).write(to: small)
        let handles = try [big, outside, small].map { try FileHandle(forReadingFrom: $0) }
        defer { handles.forEach { try? $0.close() } }

        let open = mulg_engine_open_files(LoadingTrace.prefixes([root]), LoadingTrace.minimumSize, 16)
        let real = try #require(realpath(big.path, nil).map { defer { free($0) }; return String(cString: $0) })
        #expect(open.contains(real))
        #expect(!open.contains { $0.hasSuffix("small.blk") })
        #expect(!open.contains { $0.contains(other.lastPathComponent) })
        #expect(mulg_engine_open_files(LoadingTrace.prefixes([root]), LoadingTrace.minimumSize, 0).isEmpty)
    }

    @Test("Read-ahead follows Documents and the download folders to the game folder")
    func rootsFollowGameFolderLinks() throws {
        let files = FileManager.default, base = try makeRoot()
        defer { try? files.removeItem(at: base) }
        let home = base.appendingPathComponent("Home"), game = base.appendingPathComponent("Game")
        for name in ["Library", "Library/Application Support"] {
            try files.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in ["Documents", "Library/Caches"] {
            try files.createDirectory(at: game.appendingPathComponent(name), withIntermediateDirectories: true)
            try files.createSymbolicLink(at: home.appendingPathComponent(name), withDestinationURL: game.appendingPathComponent(name))
        }
        let roots = EngineCoreModule.readAheadRoots(bundle: base.appendingPathComponent("Game.app"), home: home).map(\.path)
        #expect(roots.contains(game.appendingPathComponent("Documents").resolvingSymlinksInPath().path))
        #expect(roots.contains(game.appendingPathComponent("Library/Caches").resolvingSymlinksInPath().path))
        #expect(roots.contains(home.appendingPathComponent("Library/Application Support").resolvingSymlinksInPath().path))
        #expect(Set(roots).count == roots.count)
    }

    @Test("A full learned asset list is persisted after its first sample, without a minute of rescanning")
    func fullListFinishesEarly() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = try (0..<LoadingTrace.limit).map { try bigFile("asset-\($0).blk", in: root) }
        let handles = try assets.map { try FileHandle(forReadingFrom: $0) }
        defer { handles.forEach { try? $0.close() } }
        let trace = root.appendingPathComponent(LoadingTrace.fileName)
        LoadingTrace.record(roots: [root], to: trace, cancelled: { false })
        // The sample interval is three seconds. Allow scheduling/encoding slack,
        // while distinguishing completion from the old sixty-second scan loop.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: trace.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let saved = try JSONDecoder().decode([LoadingTrace.Asset].self, from: Data(contentsOf: trace))
        #expect(saved.count == LoadingTrace.limit)
        #expect(Set(saved.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == Set(assets.map(\.lastPathComponent)))
        #expect(saved.allSatisfy { $0.size == LoadingTrace.minimumSize })
    }

    @Test("Samples keep first-seen order without repeats, up to the limit")
    func mergesInOrder() {
        var seen = LoadingTrace.merge(["b", "a"], into: [])
        seen = LoadingTrace.merge(["a", "c"], into: seen)
        #expect(seen == ["b", "a", "c"])
        #expect(LoadingTrace.merge((0..<300).map(String.init), into: []).count == LoadingTrace.limit)
    }

    @Test("Only unchanged files under the roots are read ahead from a saved trace")
    func learnedFilesMustMatch() throws {
        let root = try makeRoot(), other = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        let kept = try bigFile("a.blk", in: root), changed = try bigFile("b.blk", in: root)
        let outside = try bigFile("c.blk", in: other)
        let assets = [kept, changed, outside].compactMap { LoadingTrace.asset(at: $0.path) }
        #expect(assets.count == 3)
        let trace = root.appendingPathComponent(LoadingTrace.fileName)
        try JSONEncoder().encode(assets).write(to: trace)
        let handle = try FileHandle(forWritingTo: changed)
        try handle.truncate(atOffset: UInt64(LoadingTrace.minimumSize) + 1)
        try handle.close()
        #expect(LoadingTrace.learned(at: trace, roots: [root]).map(\.path) == [kept.path])
        #expect(LoadingTrace.learned(at: root.appendingPathComponent("missing.json"), roots: [root]).isEmpty)
    }
}
