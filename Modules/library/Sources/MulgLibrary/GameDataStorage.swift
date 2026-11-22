#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import CryptoKit
import Foundation
import MulgContracts

/// Game downloads live beside the installed app. The sandbox's Data directory remains real;
/// only game-owned directories are redirected, leaving macOS's home-folder links intact.
public enum GameDataStorage {
    public enum Failure: Error, LocalizedError {
        case unavailable(String), conflict(String), verification(String)
        public var errorDescription: String? {
            switch self {
            case .unavailable(let path): "The game's storage is unavailable or not writable: \(path). Connect the drive and allow folder access before launching."
            case .conflict(let path): "Game data already exists at \(path). Mulg kept both copies; resolve this storage conflict before launching."
            case .verification(let path): "The copied game data did not verify: \(path). The original data has been kept."
            }
        }
    }

    struct Migration: Codable {
        let name: String
        let source: URL
        let target: URL
        let staged: URL
        let backup: URL
        var verified = false
    }
    struct Owner: Codable { let bundleIdentifier: String }
    static let names = ["Documents", "Library", "SystemData", "tmp"]

    public static func root(for app: URL, bundleIdentifier: String) throws -> URL {
        guard GameSessionLease.isValidBundleIdentifier(bundleIdentifier) else { throw GameSessionLease.Failure.invalidIdentifier }
        return app.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("Support", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// No missing volume is recreated under /Volumes. Test actual writes, including SMB ACLs.
    @discardableResult
    public static func createRoot(for app: URL, bundleIdentifier: String, paths: ContainerPaths = .current()) throws -> URL {
        let parent = app.resolvingSymlinksInPath().deletingLastPathComponent()
        guard (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw Failure.unavailable(parent.path)
        }
        let root = try root(for: app, bundleIdentifier: bundleIdentifier)
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let owner = root.appendingPathComponent("MulgSupport.json")
        if files.fileExists(atPath: owner.path) {
            guard try JSONDecoder().decode(Owner.self, from: Data(contentsOf: owner)).bundleIdentifier == bundleIdentifier else {
                throw Failure.conflict(root.path)
            }
        } else {
            try JSONEncoder().encode(Owner(bundleIdentifier: bundleIdentifier)).write(to: owner, options: .atomic)
        }
        let probe = root.appendingPathComponent(".access-" + UUID().uuidString)
        defer { try? files.removeItem(at: probe) }
        try Data("Mulg game data access".utf8).write(to: probe, options: .atomic)
        guard try Data(contentsOf: probe) == Data("Mulg game data access".utf8) else { throw Failure.unavailable(root.path) }
        try files.createDirectory(at: root.appendingPathComponent("Data"), withIntermediateDirectories: true)
        let record = locationsFile(bundleIdentifier, paths: paths)
        var roots = (try? JSONDecoder().decode([URL].self, from: Data(contentsOf: record))) ?? []
        if !roots.contains(root) {
            roots.append(root)
            try files.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(roots).write(to: record, options: .atomic)
        }
        return root
    }

    /// The user grants macOS access to the installation folder; signing separately grants
    /// the sandboxed game access to its own support folder only.
    @MainActor public static func requestAccess(for app: URL, bundleIdentifier: String) -> Bool {
        let parent = app.resolvingSymlinksInPath().deletingLastPathComponent()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = parent
        panel.prompt = "Allow Game Data"
        panel.message = "Allow access to \(parent.path). Mulg stores this game's downloads in Support/\(bundleIdentifier)/Data beside its app."
        return panel.runModal() == .OK && panel.url?.resolvingSymlinksInPath() == parent
    }

    public static func isPermissionError(_ error: any Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code))
    }

    /// Keep the detached worker's lease reference inside this call. Its async frame must
    /// finish before the host drops its lease for the token-bearing runtime handoff.
    @MainActor public static func prepareForLaunch(for app: URL, bundleIdentifier: String,
                                                  paths: ContainerPaths = .current(),
                                                  sessionLease: GameSessionLease? = nil) async throws -> URL {
        do {
            return try await Task.detached(priority: .utility) {
                try prepare(for: app, bundleIdentifier: bundleIdentifier, paths: paths, sessionLease: sessionLease)
            }.value
        } catch where isPermissionError(error) {
            guard requestAccess(for: app, bundleIdentifier: bundleIdentifier) else { throw error }
            return try await Task.detached(priority: .utility) {
                try prepare(for: app, bundleIdentifier: bundleIdentifier, paths: paths, sessionLease: sessionLease)
            }.value
        }
    }

    /// Must run off the UI thread. A session lease excludes launches throughout copying and
    /// verification. Local originals are retained outside Data as a recovery backup.
    @discardableResult
    public static func prepare(for app: URL, bundleIdentifier: String, paths: ContainerPaths = .current(),
                               sessionLease: GameSessionLease? = nil,
                               progress: @Sendable (String) -> Void = { _ in }) throws -> URL {
        let lease = try GameCleanup.acquireLease(bundleIdentifier, paths: paths, existing: sessionLease)
        defer { withExtendedLifetime(lease) {} }
        let root = try createRoot(for: app, bundleIdentifier: bundleIdentifier, paths: paths)
        let destination = root.appendingPathComponent("Data")
        let container = paths.gameContainer(for: bundleIdentifier)
        let data = container.appendingPathComponent("Data")
        let files = FileManager.default
        let initialized = ["MulgRuntimeDataReady.json", "MulgNativeLibraryReady.json"].contains { name in
            guard let bytes = try? Data(contentsOf: root.appendingPathComponent(name)) else { return false }
            return (try? JSONDecoder().decode(Owner.self, from: bytes))?.bundleIdentifier == bundleIdentifier
        }
        if initialized {
            // macOS still owns a small local Library tree (including its preferences).
            // The runtime returns actual external URLs to the game; do not remigrate this
            // structural tree over already downloaded assets on subsequent launches.
            try restoreNativeLibrary(root: root, container: container)
            return root
        }
        if !files.fileExists(atPath: data.path) {
            for name in names { try files.createDirectory(at: destination.appendingPathComponent(name), withIntermediateDirectories: true) }
            // Let macOS establish its own container metadata. The runtime redirects the
            // directories after Container Manager initializes the new sandbox.
            return root
        }
        try files.createDirectory(at: data, withIntermediateDirectories: true)
        let journal = paths.mulgStateDirectory.appendingPathComponent("DataMigrations").appendingPathComponent(bundleIdentifier + ".json")
        if files.fileExists(atPath: journal.path) {
            var migration = try JSONDecoder().decode(Migration.self, from: Data(contentsOf: journal))
            guard migration.source.deletingLastPathComponent().resolvingSymlinksInPath().path == data.resolvingSymlinksInPath().path,
                  migration.target.deletingLastPathComponent().path == destination.path,
                  migration.staged.deletingLastPathComponent().path == destination.path,
                  migration.backup.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path == container.appendingPathComponent("MulgDataBackup").resolvingSymlinksInPath().path else {
                throw Failure.conflict(journal.path)
            }
            if migration.verified {
                try publish(migration, journal: journal)
            } else {
                // Interrupted copying never alters the source. Retry using the owned stage.
                if BundleTransaction.exists(migration.staged) { try files.removeItem(at: migration.staged) }
                try copyAndVerify(&migration, journal: journal, progress: progress)
                try publish(migration, journal: journal)
            }
        }
        for name in names where !BundleTransaction.exists(data.appendingPathComponent(name)) {
            try files.createDirectory(at: data.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        let entries = try files.contentsOfDirectory(at: data, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for source in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = source.lastPathComponent
            if name == ".mulg-bootstrap-backup" { continue }
            let target = destination.appendingPathComponent(name)
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                if names.contains(name) {
                    // Resolving a dangling link leaves the source path unresolved. Compare
                    // its actual destination instead, including when Support was removed
                    // during a reinstall. Never repair links to unrelated user folders.
                    let link = try files.destinationOfSymbolicLink(atPath: source.path)
                    let linked = URL(fileURLWithPath: link, relativeTo: source.deletingLastPathComponent()).standardizedFileURL
                    let linkedPath = linked.deletingLastPathComponent().resolvingSymlinksInPath()
                        .appendingPathComponent(linked.lastPathComponent).path
                    guard linkedPath == target.path else { throw Failure.conflict(source.path) }
                    if !BundleTransaction.exists(target) {
                        try restoreMissingDirectory(name, at: target, container: container)
                    }
                    let targetValues = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard targetValues.isDirectory == true, targetValues.isSymbolicLink != true else {
                        throw Failure.conflict(target.path)
                    }
                }
                continue // Never copy Desktop/Downloads or other macOS home-folder links.
            }
            guard values.isDirectory == true else { continue }
            if BundleTransaction.exists(target) {
                // A first launch interrupted before publishing runtime readiness can leave
                // empty standard directories. Never overwrite files belonging to a game.
                guard try inventory(target).values.allSatisfy({ $0 == "directory" }) else { throw Failure.conflict(target.path) }
                try files.removeItem(at: target)
            }
            let token = UUID().uuidString
            let backup = container.appendingPathComponent("MulgDataBackup/" + token).appendingPathComponent(name)
            var migration = Migration(name: name, source: source, target: target,
                                      staged: destination.appendingPathComponent(".mulg-copy-" + token), backup: backup)
            try save(migration, journal: journal)
            try copyAndVerify(&migration, journal: journal, progress: progress)
            try publish(migration, journal: journal)
        }
        try restoreNativeLibrary(root: root, container: container)
        try JSONEncoder().encode(Owner(bundleIdentifier: bundleIdentifier))
            .write(to: root.appendingPathComponent("MulgNativeLibraryReady.json"), options: .atomic)
        progress("Game data ready: " + destination.path)
        return root
    }

    /// cfprefsd rejects a container Library symlink outside the sandbox even when the game
    /// itself has folder access. Restore a real Library/Preferences; alias game assets without
    /// copying them. This also upgrades layouts created before runtime redirection existed.
    static func restoreNativeLibrary(root: URL, container: URL) throws {
        let files = FileManager.default
        // Backup snapshots can contain the old sandbox's forwarding links. Repair
        // exact self-links at their external destinations before using the tree.
        try GameDataLayout.repairSelfLinkedDirectories(in: root.appendingPathComponent("Data", isDirectory: true))
        let external = root.appendingPathComponent("Data/Library")
        let local = container.appendingPathComponent("Data/Library")
        try files.createDirectory(at: external, withIntermediateDirectories: true)
        let linked = (try? local.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        if linked {
            let destination = try files.destinationOfSymbolicLink(atPath: local.path)
            let resolved = URL(fileURLWithPath: destination, relativeTo: local.deletingLastPathComponent())
                .standardizedFileURL.resolvingSymlinksInPath()
            guard resolved == external.resolvingSymlinksInPath() else { throw Failure.conflict(local.path) }
            let staged = local.deletingLastPathComponent().appendingPathComponent(".mulg-native-Library-" + UUID().uuidString)
            defer { if BundleTransaction.exists(staged) { try? files.removeItem(at: staged) } }
            try files.createDirectory(at: staged, withIntermediateDirectories: false)
            try populateNativeLibrary(staged, external: external)
            try BundleTransaction.flushTree(staged)
            try files.removeItem(at: local) // Only the validated symbolic link, never its target.
            do { try files.moveItem(at: staged, to: local) }
            catch {
                if !BundleTransaction.exists(local) { try? files.createSymbolicLink(atPath: local.path, withDestinationPath: destination) }
                throw error
            }
        } else {
            try files.createDirectory(at: local, withIntermediateDirectories: true)
            try populateNativeLibrary(local, external: external)
        }
    }

    static var nativeLibraryNames: Set<String> { GameDataLayout.nativeLibraryNames }

    /// Everything a game downloads belongs in the folder chosen at installation (2026-10-10, user request).
    /// Folders the game, or a framework on its behalf, created in the local Library after the last launch
    /// (only the ones that existed then were linked) are moved there, verified, and replaced by links. Not
    /// merged into a non-empty folder of the same name: both are kept and the next launch tries again.
    @discardableResult
    static func sweepLocalLibrary(_ local: URL, external: URL) throws -> [String] {
        let files = FileManager.default
        var moved: [String] = []
        guard BundleTransaction.exists(local) else { return moved }
        for item in try files.contentsOfDirectory(at: local, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let name = item.lastPathComponent
            guard !nativeLibraryNames.contains(name), !name.hasPrefix(".mulg-") else { continue }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let target = external.appendingPathComponent(name)
            if BundleTransaction.exists(target) {
                // An empty placeholder (the runtime creates Caches and Application Support) gives way.
                guard try inventory(target).values.allSatisfy({ $0 == "directory" }) else { continue }
                try files.removeItem(at: target)
            }
            let staged = external.appendingPathComponent(".mulg-copy-" + UUID().uuidString)
            defer { if BundleTransaction.exists(staged) { try? files.removeItem(at: staged) } }
            try BundleTransaction.copy(item, to: staged)
            guard try inventory(item) == inventory(staged) else { throw Failure.verification(name) }
            try files.moveItem(at: staged, to: target)
            try files.removeItem(at: item)
            try files.createSymbolicLink(at: item, withDestinationURL: target)
            moved.append(name)
        }
        return moved
    }

    private static func populateNativeLibrary(_ local: URL, external: URL) throws {
        let files = FileManager.default
        try sweepLocalLibrary(local, external: external)
        let preferences = local.appendingPathComponent("Preferences")
        if BundleTransaction.exists(preferences) {
            let type = try preferences.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard type.isDirectory == true, type.isSymbolicLink != true else { throw Failure.conflict(preferences.path) }
        } else {
            let original = external.appendingPathComponent("Preferences")
            if BundleTransaction.exists(original) {
                let type = try original.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard type.isDirectory == true, type.isSymbolicLink != true else { throw Failure.conflict(original.path) }
                try BundleTransaction.copy(original, to: preferences)
                guard try inventory(original) == inventory(preferences) else { throw Failure.verification("Preferences") }
            } else { try files.createDirectory(at: preferences, withIntermediateDirectories: false) }
        }
        for item in try files.contentsOfDirectory(at: external, includingPropertiesForKeys: [.isSymbolicLinkKey])
            where item.lastPathComponent != "Preferences" {
            let alias = local.appendingPathComponent(item.lastPathComponent)
            guard !BundleTransaction.exists(alias) else { continue } // Native state always wins.
            if (try item.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
                // macOS home-folder links were copied verbatim; restore their original relative
                // destination at the native container depth instead of following a broken link.
                try files.createSymbolicLink(atPath: alias.path,
                    withDestinationPath: files.destinationOfSymbolicLink(atPath: item.path))
            } else { try files.createSymbolicLink(at: alias, withDestinationURL: item) }
        }
    }

    /// Own deleted targets can be recovered from retained originals. Different snapshots
    /// require resolution; never choose one arbitrarily or overwrite surviving downloads.
    static func restoreMissingDirectory(_ name: String, at target: URL, container: URL) throws {
        let files = FileManager.default
        let backupRoot = container.appendingPathComponent("MulgDataBackup")
        var snapshots: [URL] = []
        if BundleTransaction.exists(backupRoot) {
            for folder in try files.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                where UUID(uuidString: folder.lastPathComponent) != nil {
                let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let candidate = folder.appendingPathComponent(name)
                if BundleTransaction.exists(candidate) {
                    let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.conflict(candidate.path) }
                    snapshots.append(candidate)
                }
            }
        }
        guard let original = snapshots.sorted(by: { $0.path < $1.path }).first else {
            try files.createDirectory(at: target, withIntermediateDirectories: false)
            return
        }
        let expected = try inventory(original)
        for snapshot in snapshots where snapshot != original {
            guard try inventory(snapshot) == expected else { throw Failure.conflict(backupRoot.path) }
        }
        let staged = target.deletingLastPathComponent().appendingPathComponent(".mulg-restore-" + UUID().uuidString)
        defer { if BundleTransaction.exists(staged) { try? files.removeItem(at: staged) } }
        try BundleTransaction.copy(original, to: staged)
        guard try inventory(staged) == expected, try inventory(original) == expected else { throw Failure.verification(name) }
        try files.moveItem(at: staged, to: target)
    }

    static func save(_ migration: Migration, journal: URL) throws {
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(migration).write(to: journal, options: .atomic)
        try BundleTransaction.flush(journal, full: true)
    }

    static func copyAndVerify(_ migration: inout Migration, journal: URL, progress: @Sendable (String) -> Void) throws {
        progress("Copying " + migration.name)
        try BundleTransaction.copy(migration.source, to: migration.staged)
        progress("Verifying " + migration.name)
        guard try inventory(migration.source) == inventory(migration.staged) else { throw Failure.verification(migration.name) }
        migration.verified = true
        try save(migration, journal: journal)
    }

    static func publish(_ migration: Migration, journal: URL) throws {
        let files = FileManager.default
        if !BundleTransaction.exists(migration.target) { try files.moveItem(at: migration.staged, to: migration.target) }
        // An interrupted publication may have already moved the original or installed the link.
        if (try? files.destinationOfSymbolicLink(atPath: migration.source.path)) == migration.target.path {
            try files.removeItem(at: journal)
            return
        }
        if BundleTransaction.exists(migration.source) {
            try files.createDirectory(at: migration.backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.moveItem(at: migration.source, to: migration.backup)
        }
        do {
            try files.createSymbolicLink(at: migration.source, withDestinationURL: migration.target)
        } catch {
            if !BundleTransaction.exists(migration.source), BundleTransaction.exists(migration.backup) {
                try files.moveItem(at: migration.backup, to: migration.source)
            }
            throw error
        }
        try files.removeItem(at: journal)
    }

    /// Compare every file's bytes, directory and symlink without following links out of the tree.
    static func inventory(_ root: URL) throws -> [String: String] {
        let root = root.resolvingSymlinksInPath()
        let files = FileManager.default
        var result: [String: String] = [:]
        var pending: [(URL, String)] = [(root, "")]
        // DirectoryEnumerator already avoids symlinks. On SMB, calling skipDescendants
        // for a link can instead suppress the next real directory's children. Visit
        // directories explicitly so link order never changes which bytes get verified.
        while let (directory, prefix) = pending.popLast() {
            for file in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]) {
                let relative = prefix + file.lastPathComponent
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
                if values.isSymbolicLink == true {
                    result[relative] = "link:" + (try files.destinationOfSymbolicLink(atPath: file.path))
                } else if values.isDirectory == true {
                    result[relative] = "directory"
                    pending.append((file, relative + "/"))
                } else if values.isRegularFile == true {
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    var hash = SHA256()
                    while let bytes = try handle.read(upToCount: 4 * 1_024 * 1_024), !bytes.isEmpty { hash.update(data: bytes) }
                    result[relative] = hash.finalize().map { String(format: "%02x", $0) }.joined()
                } else { throw Failure.verification(file.path) }
            }
        }
        return result
    }

    public static func sandboxRules(for root: URL) -> [String] {
        // Quote arbitrary user-selected volume/folder names as SBPL strings.
        let path = root.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        return ["(allow file* (subpath \"\(path)\"))"]
    }

    static func locationsFile(_ id: String, paths: ContainerPaths) -> URL {
        paths.mulgStateDirectory.appendingPathComponent("DataLocations").appendingPathComponent(id + ".json")
    }

    /// Owned locations survive a deleted library alias, allowing a later complete removal.
    public static func ownedRoots(for id: String, app: URL? = nil, paths: ContainerPaths = .current()) throws -> [URL] {
        guard GameSessionLease.isValidBundleIdentifier(id) else { throw GameSessionLease.Failure.invalidIdentifier }
        var roots = (try? JSONDecoder().decode([URL].self, from: Data(contentsOf: locationsFile(id, paths: paths)))) ?? []
        if let app { roots.append(try root(for: app, bundleIdentifier: id)) }
        return try Set(roots).filter { root in
            guard root.lastPathComponent == id, root.deletingLastPathComponent().lastPathComponent == "Support" else { throw Failure.conflict(root.path) }
            if root.path.hasPrefix("/Volumes/"), root.pathComponents.count > 2 {
                let mount = URL(fileURLWithPath: "/Volumes/" + root.pathComponents[2])
                guard FileManager.default.fileExists(atPath: mount.path) else { throw Failure.unavailable(mount.path) }
            }
            guard BundleTransaction.exists(root) else { return false }
            guard (try? JSONDecoder().decode(Owner.self, from: Data(contentsOf: root.appendingPathComponent("MulgSupport.json"))))?.bundleIdentifier == id else {
                throw Failure.conflict(root.path)
            }
            return true
        }.sorted { $0.path < $1.path }
    }

    static func activeDataLocation(for id: String, paths: ContainerPaths) throws -> URL? {
        let local = paths.gameContainer(for: id).appendingPathComponent("Data/Library")
        let roots = try ownedRoots(for: id, paths: paths)
        if let root = roots.first(where: {
            let root = $0
            return ["MulgRuntimeDataReady.json", "MulgNativeLibraryReady.json"].contains { name in
                guard let bytes = try? Data(contentsOf: root.appendingPathComponent(name)) else { return false }
                return (try? JSONDecoder().decode(Owner.self, from: bytes))?.bundleIdentifier == id
            }
        }) { return root.appendingPathComponent("Data") }
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: local.path) else { return nil }
        let library = URL(fileURLWithPath: target)
        let root = library.deletingLastPathComponent().deletingLastPathComponent()
        guard roots.contains(root) else { throw Failure.conflict(target) }
        return root.appendingPathComponent("Data")
    }

    /// A save archive must contain bytes, rather than links to another Mac's drive.
    static func backupSnapshot(for id: String, paths: ContainerPaths) throws -> (source: URL, scratch: URL?) {
        let local = paths.gameContainer(for: id).appendingPathComponent("Data")
        guard let external = try activeDataLocation(for: id, paths: paths) else { return (local, nil) }
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("Mulg-SaveSnapshot-" + UUID().uuidString)
        let snapshot = scratch.appendingPathComponent("Data")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        do {
            try BundleTransaction.copy(external, to: snapshot)
            // cfprefsd may retain the native sandbox path independently of Foundation's
            // game directory APIs. Include the game's own preferences, without user-global files.
            let preferences = local.appendingPathComponent("Library/Preferences/" + id + ".plist")
            if BundleTransaction.exists(preferences), !preferences.resolvingSymlinksInPath().path.hasPrefix(external.path + "/") {
                let target = snapshot.appendingPathComponent("Library/Preferences/" + id + ".plist")
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: preferences).write(to: target, options: .atomic)
            }
            return (snapshot, scratch)
        } catch { try? files.removeItem(at: scratch); throw error }
    }
}
#endif
