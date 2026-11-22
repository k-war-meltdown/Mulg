#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MulgContracts

/// The host's destructive operations share the runtime lease and exact per-game paths.
public enum GameCleanup {
    /// What a full removal could not finish (a disconnected drive, a refused deletion), saved for a retry.
    public struct PendingRemoval: Codable, Sendable {
        public let bundleIdentifier: String
        public let app: URL
        public let remaining: [GameRemovalScan.Item]
        public let issues: [String]
    }
    public struct IncompleteRemoval: LocalizedError, Sendable {
        public let issues: [String]
        public let report: URL
        /// Items macOS refused for lack of permission (a protected container, a drive Mulg may not
        /// write to). The host asks the player to allow access and retries.
        public var denied: [URL] = []
        public var errorDescription: String? {
            "Some game files could not be removed. Connect missing drives or allow folder access, then use Retry Incomplete Removals in Settings → Uninstall.\n\n"
                + issues.prefix(8).joined(separator: "\n") + "\n\nRemoval report: " + report.path
        }
    }
    /// macOS refused to change these items: another app's protected container, or a drive or
    /// folder Mulg has not been allowed into. Nothing after the refusal was changed.
    public struct AccessDenied: LocalizedError, Sendable {
        public let urls: [URL]
        public let reason: String
        public var errorDescription: String? { reason }
    }
    /// The items a cleanup error says macOS refused, if it is a permission refusal.
    public static func deniedItems(in error: any Error) -> [URL] {
        if let denied = error as? AccessDenied { return denied.urls }
        if let incomplete = error as? IncompleteRemoval { return incomplete.denied }
        guard isPermissionError(error) else { return [] }
        let info = (error as NSError).userInfo
        if let url = info[NSURLErrorKey] as? URL { return [url] }
        if let path = info[NSFilePathErrorKey] as? String { return [URL(fileURLWithPath: path)] }
        return []
    }
    static func isPermissionError(_ error: any Error) -> Bool {
        if GameDataStorage.isPermissionError(error) { return true }
        guard let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return GameDataStorage.isPermissionError(underlying)
    }
    /// Runs one cleanup step; a permission refusal names the item so the host can ask for access.
    static func guarded(_ url: URL, _ body: () throws -> Void) throws {
        do { try body() }
        catch where isPermissionError(error) {
            throw AccessDenied(urls: [url], reason: error.localizedDescription)
        }
    }
    static func removalRecord(_ id: String, paths: ContainerPaths) -> URL {
        paths.mulgStateDirectory.appendingPathComponent("Removals").appendingPathComponent(id + ".json")
    }
    /// Unreadable records are skipped, so one damaged file never blocks every other removal.
    public static func pendingRemovals(paths: ContainerPaths = .current()) throws -> [PendingRemoval] {
        let folder = paths.mulgStateDirectory.appendingPathComponent("Removals")
        guard BundleTransaction.exists(folder) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { file in
                guard let record = try? JSONDecoder().decode(PendingRemoval.self, from: Data(contentsOf: file)),
                      GameSessionLease.isValidBundleIdentifier(record.bundleIdentifier),
                      file.deletingPathExtension().lastPathComponent == record.bundleIdentifier else { return nil }
                return record
            }.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }

    public static func acquireLease(_ identifier: String, paths: ContainerPaths = .current(),
                                    existing: GameSessionLease? = nil) throws -> GameSessionLease {
        guard GameSessionLease.isValidBundleIdentifier(identifier),
              existing == nil || existing?.bundleIdentifier == identifier else {
            throw GameSessionLease.Failure.invalidIdentifier
        }
        let lease = try existing ?? GameSessionLease(bundleIdentifier: identifier, paths: paths)
        guard !GameWatcher.isRunning(identifier) else { throw GameSessionLease.Failure.busy }
        return lease
    }

    /// Deletes an item for good. External drives often refuse a plain removal: files copied from
    /// another Mac keep the locked (uchg) flag or read-only folders. Those are unlocked, never by
    /// following a link, and the removal retried. exFAT/FAT drives also get the `._` companion.
    public static func removeStubbornly(_ url: URL) throws {
        let files = FileManager.default
        do { try files.removeItem(at: url) }
        catch {
            guard BundleTransaction.exists(url) else { return }
            // A failed unlink of a shortcut must never unlock or traverse its target.
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw error }
            unlock(url)
            if let entries = files.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) {
                for case let item as URL in entries where (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
                    unlock(item)
                }
            }
            try files.removeItem(at: url)
        }
        let companion = url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent)
        if (try? companion.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile) == true,
           (try? companion.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
           let handle = try? FileHandle(forReadingFrom: companion) {
            let magic = try? handle.read(upToCount: 4)
            try? handle.close()
            // Only a genuine AppleDouble sidecar belongs to the removed payload.
            guard magic == Data([0x00, 0x05, 0x16, 0x07]) else { return }
            try? files.removeItem(at: companion)
        }
    }

    private static func unlock(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { return }
        if info.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0 {
            _ = lchflags(url.path, info.st_flags & ~UInt32(UF_IMMUTABLE | UF_APPEND))
        }
        let wanted = info.st_mode | ((info.st_mode & S_IFMT) == S_IFDIR ? S_IRWXU : S_IRUSR | S_IWUSR)
        if wanted != info.st_mode { _ = chmod(url.path, wanted & 0o7777) }
        // Parent folders may contain unrelated games or personal files. Their
        // permissions stay untouched; access refusals use the existing grant UI.
    }

    /// Trash when the drive supports it; drives without a Trash (exFAT, network shares, some
    /// external disks) refuse, and the cleanup the player asked for then deletes instead.
    static func trashOrRemove(_ url: URL) throws {
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        catch {
            guard BundleTransaction.exists(url), !GameRemovalScan.isOnDisconnectedVolume(url) else { throw error }
            try removeStubbornly(url)
        }
    }

    public static func cacheItems(for identifier: String, paths: ContainerPaths = .current()) throws -> [URL] {
        guard GameSessionLease.isValidBundleIdentifier(identifier) else { throw GameSessionLease.Failure.invalidIdentifier }
        let library = paths.home.appendingPathComponent("Library", isDirectory: true)
        return [("Containers", [""]), ("Application Scripts", [""]), ("Caches", [""]),
                ("Application Support", [""]), ("Preferences", [".plist"]),
                ("HTTPStorages", ["", ".binarycookies"]), ("Saved Application State", ["", ".savedState"]),
                ("WebKit", [""]), ("Cookies", [".binarycookies"]), ("Logs", [""])]
            .flatMap { folder, suffixes in
                suffixes.map { library.appendingPathComponent(folder).appendingPathComponent(identifier + $0) }
            }
    }

    public static func trashCaches(for identifier: String, paths: ContainerPaths = .current(),
                                   sessionLease: GameSessionLease? = nil) throws {
        let lease = try acquireLease(identifier, paths: paths, existing: sessionLease)
        defer { withExtendedLifetime(lease) {} }
        // Every item is tried; refusals are collected so the player is asked once for all of them.
        var denied: [URL] = [], reason = ""
        func attempt(_ url: URL, _ body: () throws -> Void) throws {
            do { try guarded(url, body) } catch let refusal as AccessDenied { denied += refusal.urls; reason = refusal.reason }
        }
        let roots = try GameDataStorage.ownedRoots(for: identifier, paths: paths)
        for root in roots { try attempt(root) { try trashOrRemove(root) } }
        for item in try cacheItems(for: identifier, paths: paths) where FileManager.default.fileExists(atPath: item.path) {
            try attempt(item) { try FileManager.default.trashItem(at: item, resultingItemURL: nil) }
        }
        if !denied.isEmpty { throw AccessDenied(urls: denied, reason: reason) }
        // The location index goes last: a refused Support folder must stay findable for the retry.
        let locations = GameDataStorage.locationsFile(identifier, paths: paths)
        if BundleTransaction.exists(locations) { try FileManager.default.removeItem(at: locations) }
    }

    public static func removeCredentials(for identifier: String, paths: ContainerPaths = .current(),
                                         sessionLease: GameSessionLease? = nil) throws {
        let lease = try acquireLease(identifier, paths: paths, existing: sessionLease)
        defer { withExtendedLifetime(lease) {} }
        // Remove companions first so a failed deletion cannot resurrect the database's contents.
        for item in try credentialItems(for: identifier, paths: paths).reversed()
            where FileManager.default.fileExists(atPath: item.path) {
            try guarded(item) { try FileManager.default.removeItem(at: item) }
        }
    }

    public static func credentialItems(for identifier: String, paths: ContainerPaths = .current()) throws -> [URL] {
        guard GameSessionLease.isValidBundleIdentifier(identifier) else { throw GameSessionLease.Failure.invalidIdentifier }
        let legacy = paths.mulgChainDirectory.appendingPathComponent(identifier)
        let database = paths.mulgChainDatabase(for: identifier)
        return [legacy, legacy.appendingPathExtension(ContainerPaths.legacyVaultExtension), database,
                URL(fileURLWithPath: database.path + "-wal"), URL(fileURLWithPath: database.path + "-shm"),
                paths.mulgChainKey(for: identifier)]
    }

    public static func pruneItems(for identifier: String, paths: ContainerPaths = .current()) throws -> [URL] {
        try cacheItems(for: identifier, paths: paths) + credentialItems(for: identifier, paths: paths)
            + [paths.settingsFile(for: identifier), paths.keymapDirectory(for: identifier),
               paths.mulgContainer.appendingPathComponent("Entitlements").appendingPathComponent(identifier + ".plist")]
    }

    /// Explicit full uninstall. With an `inventory` from `GameRemovalScan.discover`, every
    /// metadata-verified copy and Support folder in an install location on any mounted drive is removed too,
    /// matching IPAs and save versions are included. Shared App Groups and name-only
    /// matches are kept. Ownership is checked immediately before each payload is removed. Never
    /// traverses an arbitrary link. A disconnected drive or refused deletion does not stop the rest:
    /// what is left is saved (`pendingRemovals`) and reported as `IncompleteRemoval`.
    ///
    /// The Library locations named only by the bundle ID (Containers, Application Support, Caches, Preferences,
    /// cookies, saved state) go through `trash`: an iPad game and its native Mac version often share one bundle
    /// ID. When the inventory detects a native version or an incomplete scan, these
    /// shared paths are kept. Other callers retain the supplied Trash behavior.
    public static func removeCompletely(app: URL, bundleIdentifier id: String, paths: ContainerPaths = .current(),
                                        sessionLease: GameSessionLease? = nil,
                                        inventory: GameRemovalScan.Inventory? = nil,
                                        remove: (URL) throws -> Void = { try removeStubbornly($0) },
                                        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                                        trashLeftover: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        let lease = try acquireLease(id, paths: paths, existing: sessionLease)
        defer { withExtendedLifetime(lease) {} }
        try BundleTransaction.recover(id, paths: paths)
        try BundleTransaction.retryCleanup(id, paths: paths, strict: true)
        let installed = URL(fileURLWithPath: app.resolvingSymlinksInPath().standardizedFileURL.path)
        guard inventory == nil || (inventory?.bundleIdentifier == id && inventory?.app.path == installed.path) else {
            throw GameDataStorage.Failure.conflict(app.path)
        }
        if BundleTransaction.exists(installed) {
            guard GameInstaller.infoPlist(installed)?["CFBundleIdentifier"] as? String == id else {
                throw GameDataStorage.Failure.conflict(installed.path)
            }
        }
        var problems = inventory?.issues ?? []
        var remaining: [GameRemovalScan.Item] = []
        // Recorded Support folders. A disconnected drive no longer aborts everything: it is kept for a retry.
        var discovered = inventory?.items ?? []
        if inventory == nil {
            let recorded = (try? JSONDecoder().decode([URL].self, from: Data(contentsOf: GameDataStorage.locationsFile(id, paths: paths)))) ?? []
            for root in Set(recorded + [try GameDataStorage.root(for: installed, bundleIdentifier: id)]) {
                guard root.lastPathComponent == id, root.deletingLastPathComponent().lastPathComponent == "Support" else {
                    throw GameDataStorage.Failure.conflict(root.path)
                }
                discovered.append(GameRemovalScan.Item(url: root, kind: .support))
            }
            if BundleTransaction.exists(installed) { discovered.append(GameRemovalScan.Item(url: installed, kind: .bundle)) }
        }
        if let old = try pendingRemovals(paths: paths).first(where: { $0.bundleIdentifier == id }) { discovered += old.remaining }
        discovered += (inventory?.unavailableRoots ?? []).map { GameRemovalScan.Item(url: $0, kind: .support) }
        let unique = Dictionary(discovered.map { (URL(fileURLWithPath: $0.url.standardizedFileURL.path).path, $0) },
                                uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.url.path < $1.url.path }

        var items = try pruneItems(for: id, paths: paths)
        let state = paths.mulgStateDirectory
        items += [paths.diagnosticsDirectory(for: id), paths.shaderArchiveDirectory(for: id),
                  paths.safeModeMarker(for: id), paths.safeModeMarker(for: id).appendingPathExtension("last.json"),
                  state.appendingPathComponent("DataMigrations/" + id + ".json"),
                  paths.cameraCalibrationFile(for: id),
                  state.appendingPathComponent("SandboxPolicy/" + id + ".plist"),
                  state.appendingPathComponent("SaveRestores/" + id + ".plist"),
                  paths.settingsFile(for: id).appendingPathExtension("lock")]
        let aliases = paths.home.appendingPathComponent("Applications/Mulg")
        for alias in (try? FileManager.default.contentsOfDirectory(at: aliases, includingPropertiesForKeys: nil)) ?? [] {
            if GameInstaller.infoPlist(alias)?["CFBundleIdentifier"] as? String == id { items.append(alias); continue }
            // Current shortcuts are Finder alias files pointing at the installed game.
            guard (try? alias.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true,
                  let target = try? URL(resolvingAliasFileAt: alias, options: [.withoutUI, .withoutMounting]) else { continue }
            if target.resolvingSymlinksInPath().standardizedFileURL.path == installed.path
                || GameInstaller.infoPlist(target)?["CFBundleIdentifier"] as? String == id { items.append(alias) }
        }
        let libraryEntry = paths.applicationsDirectory.appendingPathComponent(id + ".app")
        // A dangling library link (drive unplugged) is still removable; never resolve it before unlinking.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: libraryEntry.path)) != nil
            || GameInstaller.infoPlist(libraryEntry)?["CFBundleIdentifier"] as? String == id {
            items.append(libraryEntry)
        }
        let shared = Set(try cacheItems(for: id, paths: paths))

        // Persist before deleting: a crash or unplugged disk leaves a retryable inventory.
        let record = removalRecord(id, paths: paths)
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(PendingRemoval(bundleIdentifier: id, app: installed, remaining: unique, issues: []))
            .write(to: record, options: .atomic)

        var removed: Set<String> = [], denied: [URL] = []
        for item in unique {
            if GameRemovalScan.isOnDisconnectedVolume(item.url) {
                remaining.append(item); problems.append("Drive disconnected: " + item.url.path); continue
            }
            guard BundleTransaction.exists(item.url) else { continue }
            guard GameRemovalScan.validates(item, identifier: id, selectedApp: installed) else {
                if item.kind == .support || item.url.path == installed.path {
                    remaining.append(item); problems.append("Ownership changed or could not be verified: " + item.url.path)
                }
                continue
            }
            do {
                switch item.kind {
                case .bundle, .support, .archive, .backup: try remove(item.url)
                case .group: try trash(item.url)
                case .leftover: continue // Old name-only matches are kept, including pending records.
                }
                removed.insert(item.url.path)
            }
            catch {
                remaining.append(item); problems.append(item.url.path + ": " + error.localizedDescription)
                if isPermissionError(error) { denied.append(item.url) }
            }
        }
        // A failure must not prevent trying the other locations.
        for item in items where !removed.contains(item.path) && BundleTransaction.exists(item) {
            // A native Mac version with the same bundle ID can share these files.
            // An incomplete scan also cannot establish exclusive ownership.
            if shared.contains(item), inventory.map({ !$0.nativeApps.isEmpty || !$0.issues.isEmpty }) == true { continue }
            removed.insert(item.path)
            do { if shared.contains(item) { try trash(item) } else { try remove(item) } }
            catch {
                problems.append(item.path + ": " + error.localizedDescription)
                if isPermissionError(error) { denied.append(item) }
            }
        }
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
            where (key.hasPrefix("gui.") || key.hasPrefix("library.")) && key.hasSuffix("." + id) {
            defaults.removeObject(forKey: key)
        }
        if !problems.isEmpty || !remaining.isEmpty {
            // Keep the location index and exact failed payloads until a later retry.
            try JSONEncoder().encode(PendingRemoval(bundleIdentifier: id, app: installed, remaining: remaining, issues: problems))
                .write(to: record, options: .atomic)
            throw IncompleteRemoval(issues: problems, report: record, denied: denied)
        }
        let locations = GameDataStorage.locationsFile(id, paths: paths)
        if BundleTransaction.exists(locations) { try FileManager.default.removeItem(at: locations) }
        if BundleTransaction.exists(record) { try FileManager.default.removeItem(at: record) }
    }
}
#endif
