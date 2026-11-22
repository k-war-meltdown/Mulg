import Foundation
import MulgEngineHooks

/// The learned read-ahead order (`engine.readAhead`). During its first minute, a utility queue
/// samples which big files the game holds open (libproc; no hook sees the game's opens), and the
/// next launch reads those ahead first, in the order the game opened them. Only files under the
/// read-ahead roots are kept, so learning changes the order, never what may be read ahead; a file
/// whose size or date has changed since is dropped.
nonisolated enum LoadingTrace {
    struct Asset: Codable, Equatable, Sendable {
        let path: String
        let size: Int64
        let modified: Double
    }

    static let fileName = "loading-trace.json"
    static let limit = 128
    /// The read-ahead threshold: smaller files are not worth an advisory read.
    static let minimumSize: Int64 = 8 << 20
    static let sampleInterval: Double = 3
    static let samples = 20
    private static let queue = DispatchQueue(label: "io.mulg.loading-trace", qos: .utility)

    /// Root folders as path prefixes, as given and as realpath(3) has them: the kernel reports
    /// real paths, and Foundation's symlink resolution would strip /private again.
    static func prefixes(_ roots: [URL]) -> [String] {
        var prefixes: [String] = []
        for root in roots {
            let given = root.standardizedFileURL.path
            let real = realpath(given, nil).map { defer { free($0) }; return String(cString: $0) }
            for path in [given, real].compactMap({ $0 }) where !prefixes.contains(path + "/") {
                prefixes.append(path + "/")
            }
        }
        return prefixes
    }

    /// The learned files that are still as recorded, in the order the game opened them.
    static func learned(at file: URL, roots: [URL]) -> [URL] {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([Asset].self, from: data) else { return [] }
        let prefixes = prefixes(roots)
        return saved.prefix(limit)
            .filter { asset in prefixes.contains { asset.path.hasPrefix($0) } && Self.asset(at: asset.path) == asset }
            .map { URL(fileURLWithPath: $0.path) }
    }

    static func asset(at path: String) -> Asset? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int64(info.st_size) >= minimumSize else { return nil }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        return Asset(path: path, size: Int64(info.st_size), modified: modified)
    }

    /// Samples every `sampleInterval` seconds, `samples` times, then saves what was seen to `file`.
    /// Cancelling stops early and keeps what was seen; a launch that saw nothing keeps the old trace.
    static func record(roots: [URL], to file: URL, cancelled: @escaping @Sendable () -> Bool) {
        let paths = prefixes(roots)
        guard !paths.isEmpty, !cancelled() else { return }
        sample(paths, seen: [], left: samples, file: file, cancelled: cancelled)
    }

    /// One sample: the files under `prefixes` the game holds open now, appended in first-seen order.
    static func merge(_ open: [String], into seen: [String]) -> [String] {
        guard !open.isEmpty, seen.count < limit else { return seen }
        var seen = seen
        var known = Set(seen)
        for path in open {
            guard seen.count < limit else { break }
            if known.insert(path).inserted { seen.append(path) }
        }
        return seen
    }

    private static func sample(_ prefixes: [String], seen: [String], left: Int, file: URL,
                               cancelled: @escaping @Sendable () -> Bool) {
        queue.asyncAfter(deadline: .now() + sampleInterval) {
            let wasCancelled = cancelled()
            let seen = wasCancelled ? seen : merge(mulg_engine_open_files(prefixes, minimumSize, UInt(limit)), into: seen)
            // Once full, merge cannot add another path. Persist the same bounded
            // list now instead of repeatedly inspecting every open descriptor.
            let stop = wasCancelled || left <= 1 || seen.count >= limit
            guard stop else { return sample(prefixes, seen: seen, left: left - 1, file: file, cancelled: cancelled) }
            let assets = seen.compactMap(asset(at:))
            guard !assets.isEmpty else { return }
            ReportWriter.shared.write(assets, to: file)
        }
    }
}
