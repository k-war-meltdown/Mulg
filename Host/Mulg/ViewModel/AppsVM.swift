//
//  AppsVM.swift
//  Mulg
//

import Foundation
import MulgGUI

// Published values are only written inside the MainActor task in fetchApps().
class AppsVM: ObservableObject, @unchecked Sendable {

    public static let appDirectory = GameRuntime.mulgContainer.appendingPathComponent("Applications")

    static let shared = AppsVM()

    private init() {
        try? AppsVM.ensureBaseDirectoriesExist()
        GameRuntime.installOnSystem()
        fetchApps()
    }

    static func ensureBaseDirectoriesExist() throws {
        try FileManager.default.createDirectory(
            at: appDirectory,
            withIntermediateDirectories: true
        )
    }

    @Published var filteredApps: [MulgGame] = []
    @Published var apps: [MulgGame] = []
    @Published var searchText: String = "" {
        didSet { filterApps() }
    }
    @Published var updatingApps = true
    /// Game objects by bundle URL, with the `stamp(of:)` they were built from (main actor only).
    private var gameCache: [URL: (game: MulgGame, stamp: [Date?])] = [:]

    /// The game bundles in the library, with their `stamp(of:)`. Any thread.
    nonisolated private static func scanLibrary() -> [(url: URL, stamp: [Date?])] {
        do {
            let directoryContents = try FileManager.default
                .contentsOfDirectory(at: appDirectory, includingPropertiesForKeys: nil, options: [])
            // Games installed in another folder are links here; list them at their real place.
            return directoryContents.map { $0.resolvingSymlinksInPath() }
                .filter { $0.pathExtension.contains("app")
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map { ($0, stamp(of: $0)) }
                .filter { $0.stamp.first.flatMap { $0 } != nil }  // no Info.plist: not a game
        } catch {
            print(error)
            return []
        }
    }

    /// Modification dates of Info.plist and the signature's CodeResources: editing metadata,
    /// re-signing and adding or removing the runtime each change one of them.
    nonisolated private static func stamp(of app: URL) -> [Date?] {
        ["Info.plist", "_CodeSignature/CodeResources"].map {
            (try? app.appendingPathComponent($0).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
    }

    @discardableResult
    func fetchApps() -> Task<Void, Never> {
        Task { @MainActor in
            updatingApps = true

            // A game whose Info.plist and signature are unchanged keeps its object: rebuilding it
            // reloads keymaps and recreates its Finder alias. The list is replaced once, so the
            // library does not empty and refill on every refresh.
            var games: [MulgGame] = []
            var cache: [URL: (game: MulgGame, stamp: [Date?])] = [:]
            // The folder walk and file dates are read off the main thread; only new or changed
            // games are built here.
            let library = await Task.detached(priority: .userInitiated) { AppsVM.scanLibrary() }.value
            for (sub, stamp) in library {
                let app: MulgGame
                if let known = gameCache[sub], known.stamp == stamp {
                    app = known.game
                    // The game and the Performance tab also write settings: read them again,
                    // as a new object would.
                    _ = app.settings.decode()
                } else {
                    app = MulgGame(appUrl: sub)
                    // Games that play by keyboard get Mulg's keymap when theirs is still empty.
                    BundledKeymaps.seed(app.info.bundleIdentifier)
                    print("Application installed under:", sub.path)
                }
                cache[sub] = (app, stamp)
                games.append(app)
            }
            gameCache = cache
            apps = games

            filterApps()

            do {
                if !FileManager.default.fileExists(atPath: MulgGame.bundleIDCacheURL.path),
                   let firstBundleID = apps.first?.info.bundleIdentifier {
                    try "\(firstBundleID)\n"
                        .write(to: MulgGame.bundleIDCacheURL, atomically: false, encoding: .utf8)
                }

                var known = Set(try MulgGame.bundleIDCache)
                for bundleId in apps.map({ $0.info.bundleIdentifier }) where known.insert(bundleId).inserted {
                    if let bundleID = "\(bundleId)\n".data(using: .utf8) {
                        let cacheFile = try FileHandle(forUpdating: MulgGame.bundleIDCacheURL)
                        try cacheFile.seekToEnd()
                        try cacheFile.write(contentsOf: bundleID)
                        try cacheFile.close()
                    }
                }
            } catch {
                Log.shared.error(error)
            }

            updatingApps = false
        }
    }

    /// Searching only filters the current library; it must not recreate game objects, seed
    /// keymaps or touch the filesystem on every keystroke.
    private func filterApps() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredApps = apps.filter { query.isEmpty || $0.searchText.localizedStandardContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
