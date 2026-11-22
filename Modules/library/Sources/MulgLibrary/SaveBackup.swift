// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MulgContracts

/// Where a long operation (backup, restore, export) is, for the Mulg app to show. `canCancel` is true
/// until the operation starts changing something that cannot be left half done; cancelling before
/// that throws `CancellationError` and leaves nothing behind.
public struct OperationProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        case gameData, settings, keymaps       // saved data, backed up or put back
        case safetyCopy                        // the current saves, before a restore replaces them
        case logs, measurements, archive       // diagnostics export
    }

    public let stage: Stage
    /// Stages finished before this one, out of `total`.
    public let completed: Int
    public let total: Int
    public let canCancel: Bool

    /// Reports the stage, and stops here when the operation was cancelled and may still be.
    static func begin(_ stage: Stage, _ completed: Int, of total: Int, canCancel: Bool = true,
                      _ report: (OperationProgress) -> Void) throws {
        if canCancel { try Task.checkCancellation() }
        report(OperationProgress(stage: stage, completed: completed, total: total, canCancel: canCancel))
    }
}

/// Backs up a game's saved data, settings and keymaps to a folder the user picks, such as
/// iCloud Drive or an external disk, with dated versions (PLAN.md §13.3). iCloud sync inside
/// re-signed games usually does not work (§11.5), so this is how saves move between Macs.
///
/// Layout: `<folder>/<bundle ID>/<yyyy-MM-dd_HH-mm-ss>/` holding `Data.zip` (the game
/// container's `Data` folder), `Settings.plist` and `Keymapping.zip`.
// ponytail: the MulgChain keychain (account tokens) is left out on purpose; sign in again on
// the other Mac. Add it behind an explicit option if players ask.
public struct SaveBackup: Sendable {
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case notAVersion(String)

        public var description: String {
            switch self {
            case let .notAVersion(path): "\(path) is not a backup. Pick a dated folder inside the game's backup folder."
            }
        }
    }

    /// What a version may hold; a folder with none of these is not one.
    static let versionFiles = ["Data.zip", "Settings.plist", "Keymapping.zip"]

    public let paths: ContainerPaths
    public let folder: URL

    public init(folder: URL, paths: ContainerPaths = .current()) {
        self.folder = folder
        self.paths = paths
    }

    /// The folder name of a version, in UTC so versions from different Macs sort together.
    static func versionName(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let numbers = [parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second].map { $0 ?? 0 }
        return String(format: "%04d-%02d-%02d_%02d-%02d-%02d", numbers[0], numbers[1], numbers[2],
                      numbers[3], numbers[4], numbers[5])
    }

    /// Existing versions, newest first.
    public func versions(of bundleIdentifier: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: gameFolder(bundleIdentifier).path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted(by: >).map {
            gameFolder(bundleIdentifier).appendingPathComponent($0, isDirectory: true)
        }
    }

    /// Writes a new version and returns its folder.
    @discardableResult
    public func backUp(_ bundleIdentifier: String, date: Date? = nil,
                       progress: (OperationProgress) -> Void = { _ in }) throws -> URL {
        let lease = try GameSessionLease(bundleIdentifier: bundleIdentifier, paths: paths)
        defer { withExtendedLifetime(lease) {} }
        guard !GameWatcher.isRunning(bundleIdentifier) else { throw GameSessionLease.Failure.busy }
        try SettingsStore(paths: paths).withExclusiveAccess(bundleIdentifier: bundleIdentifier) {
            try Self.recover(bundleIdentifier, paths: paths)
        }
        return try backUpUnlocked(bundleIdentifier, date: date, progress: progress)
    }

    private func backUpUnlocked(_ bundleIdentifier: String, date: Date? = nil,
                               progress: (OperationProgress) -> Void = { _ in }) throws -> URL {
        let files = FileManager.default
        var chosenDate = date ?? .now
        if date == nil {
            while files.fileExists(atPath: gameFolder(bundleIdentifier).appendingPathComponent(Self.versionName(chosenDate)).path) {
                chosenDate += 1
            }
        }
        let version = gameFolder(bundleIdentifier).appendingPathComponent(Self.versionName(chosenDate), isDirectory: true)
        // Never write into an existing version: it may be the one being restored.
        guard !files.fileExists(atPath: version.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: version.path])
        }
        // Written under a hidden name and renamed when complete, so a failed backup (disk full,
        // drive unplugged) never shows up as a version that could be restored.
        let partial = version.deletingLastPathComponent()
            .appendingPathComponent("." + version.lastPathComponent + "-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: partial, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: partial) }
        let data = paths.gameContainer(for: bundleIdentifier).appendingPathComponent("Data", isDirectory: true)
        try OperationProgress.begin(.gameData, 0, of: 3, progress)
        if files.fileExists(atPath: data.path) {
            let snapshot = try GameDataStorage.backupSnapshot(for: bundleIdentifier, paths: paths)
            defer { if let scratch = snapshot.scratch { try? files.removeItem(at: scratch) } }
            try zip(snapshot.source, to: partial.appendingPathComponent("Data.zip"))
        }
        let settings = paths.settingsFile(for: bundleIdentifier)
        try OperationProgress.begin(.settings, 1, of: 3, progress)
        try SettingsStore(paths: paths).withExclusiveAccess(bundleIdentifier: bundleIdentifier) {
            if files.fileExists(atPath: settings.path) {
                try files.copyItem(at: settings, to: partial.appendingPathComponent("Settings.plist"))
            }
        }
        let keymaps = paths.keymapDirectory(for: bundleIdentifier)
        try OperationProgress.begin(.keymaps, 2, of: 3, progress)
        if files.fileExists(atPath: keymaps.path) {
            try zip(keymaps, to: partial.appendingPathComponent("Keymapping.zip"))
        }
        try files.moveItem(at: partial, to: version)
        return version
    }

    /// Puts a version back. The current state is backed up first, so a wrong pick can be
    /// undone; that safety version is returned. The game must not be running.
    @discardableResult
    public func restore(_ version: URL, bundleIdentifier: String,
                        progress: (OperationProgress) -> Void = { _ in }) throws -> URL {
        let lease = try GameSessionLease(bundleIdentifier: bundleIdentifier, paths: paths)
        defer { withExtendedLifetime(lease) {} }
        guard !GameWatcher.isRunning(bundleIdentifier) else { throw GameSessionLease.Failure.busy }
        try SettingsStore(paths: paths).withExclusiveAccess(bundleIdentifier: bundleIdentifier) {
            try Self.recover(bundleIdentifier, paths: paths)
        }
        return try restoreUnlocked(version, bundleIdentifier: bundleIdentifier, progress: progress)
    }

    private func restoreUnlocked(_ version: URL, bundleIdentifier: String,
                                 progress: (OperationProgress) -> Void) throws -> URL {
        let files = FileManager.default
        guard Self.versionFiles.contains(where: { files.fileExists(atPath: version.appendingPathComponent($0).path) }) else {
            throw Failure.notAVersion(version.path)
        }
        try Task.checkCancellation()
        // Extract and validate every part before creating the recovery record or replacing anything.
        var items: [RestoreItem] = []
        let journal = Self.journal(bundleIdentifier, paths)
        defer {
            if !BundleTransaction.exists(journal) {
                for item in items { try? files.removeItem(at: item.staged) }
            }
        }
        let destinations = try Self.destinations(bundleIdentifier, paths)
        for (name, target) in Swift.zip(Self.versionFiles, destinations) {
            let source = version.appendingPathComponent(name)
            guard files.fileExists(atPath: source.path) else { continue }
            let parent = target.deletingLastPathComponent()
            try files.createDirectory(at: parent, withIntermediateDirectories: true)
            let token = UUID().uuidString
            let staged = parent.appendingPathComponent(".mulg-restore-stage-" + token)
            let backup = parent.appendingPathComponent(".mulg-restore-backup-" + token)
            items.append(RestoreItem(target: target, staged: staged, backup: backup, hadTarget: BundleTransaction.exists(target)))
            if name == "Settings.plist" {
                let data = try Data(contentsOf: source)
                guard try PropertyListSerialization.propertyList(from: data, format: nil) is [String: Any]
                else { throw CocoaError(.propertyListReadCorrupt) }
                try data.write(to: staged, options: .atomic)
            } else {
                let unpack = parent.appendingPathComponent(".mulg-restore-unpack-" + token)
                try files.createDirectory(at: unpack, withIntermediateDirectories: true)
                defer { try? files.removeItem(at: unpack) }
                try Command.run("/usr/bin/ditto", ["-x", "-k", source.path, unpack.path])
                let extracted = unpack.appendingPathComponent(target.lastPathComponent)
                let type = try extracted.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard type.isDirectory == true, type.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
                try files.moveItem(at: extracted, to: staged)
            }
            try BundleTransaction.flushTree(staged)
            try Task.checkCancellation()
        }
        try OperationProgress.begin(.safetyCopy, 0, of: 4, progress)
        let safety = try backUpUnlocked(bundleIdentifier)
        try Task.checkCancellation()  // the last chance: the safety copy is kept, nothing is replaced
        var record = RestoreRecord(items: items, committed: false)
        // Archive work stays outside the settings lock so other windows remain responsive.
        // Only publication/rollback excludes settings writers; the game lease covers the whole restore.
        try SettingsStore(paths: paths).withExclusiveAccess(bundleIdentifier: bundleIdentifier) {
            try Self.save(record, bundleIdentifier, paths)
            do {
                for (index, target) in destinations.enumerated() {
                    try OperationProgress.begin([.gameData, .settings, .keymaps][index], index + 1, of: 4, canCancel: false, progress)
                    guard let item = items.first(where: { $0.target == target }) else { continue }
                    if item.hadTarget { try BundleTransaction.move(item.target, item.backup) }
                    try BundleTransaction.move(item.staged, item.target)
                }
                record.committed = true
                try Self.save(record, bundleIdentifier, paths)
            } catch {
                try Self.recover(bundleIdentifier, paths: paths)
                throw error
            }
        }
        // Committed cleanup never changes a live target; large old save trees can be removed unlocked.
        try Self.recover(bundleIdentifier, paths: paths)
        return safety
    }

    /// What a version holds, for showing before it replaces the current saves; nil when the folder is
    /// not a version.
    public struct Preview: Sendable, Equatable {
        public enum Part: Sendable, Equatable { case gameData, settings, keymaps }

        public struct Item: Sendable, Equatable {
            public let part: Part
            public let bytes: Int64
        }

        /// When it was made; nil if the folder name is not a backup date.
        public let date: Date?
        public let items: [Item]
    }

    public static func preview(of version: URL) -> Preview? {
        let files = FileManager.default
        let parts: [(String, Preview.Part)] = [("Data.zip", .gameData), ("Settings.plist", .settings), ("Keymapping.zip", .keymaps)]
        let items = parts.compactMap { name, part -> Preview.Item? in
            let file = version.appendingPathComponent(name)
            guard files.fileExists(atPath: file.path) else { return nil }
            let size = (try? files.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            return Preview.Item(part: part, bytes: size)
        }
        guard !items.isEmpty else { return nil }
        return Preview(date: versionDate(version.lastPathComponent), items: items)
    }

    /// The date in a version folder name (see `versionName`).
    static func versionDate(_ name: String) -> Date? {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = .gmt
        format.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return format.date(from: name)
    }

    func gameFolder(_ bundleIdentifier: String) -> URL {
        folder.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// Zips a folder with its name at the top, as Finder's Compress does.
    func zip(_ source: URL, to archive: URL) throws {
        try Command.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, archive.path])
    }

    struct RestoreItem: Codable {
        let target: URL
        let staged: URL
        let backup: URL
        let hadTarget: Bool
    }
    struct RestoreRecord: Codable { let items: [RestoreItem]; var committed: Bool }

    static func destinations(_ id: String, _ paths: ContainerPaths) throws -> [URL] {
        [try GameDataStorage.activeDataLocation(for: id, paths: paths) ?? paths.gameContainer(for: id).appendingPathComponent("Data"), paths.settingsFile(for: id), paths.keymapDirectory(for: id)]
    }
    static func journal(_ id: String, _ paths: ContainerPaths) -> URL {
        paths.mulgStateDirectory.appendingPathComponent("SaveRestores").appendingPathComponent(id + ".plist")
    }
    static func save(_ record: RestoreRecord, _ id: String, _ paths: ContainerPaths) throws {
        let file = journal(id, paths)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try PropertyListEncoder().encode(record).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try BundleTransaction.flush(file, full: true)
        try BundleTransaction.flush(file.deletingLastPathComponent())
    }

    /// Caller holds the session lease, and the settings lock for rollback. A surviving record restores all old parts
    /// unless the commit marker was durably published. Recovery is safe to repeat after a crash.
    public static func recover(_ id: String, paths: ContainerPaths = .current()) throws {
        guard GameSessionLease.isValidBundleIdentifier(id) else { throw GameSessionLease.Failure.invalidIdentifier }
        let file = journal(id, paths), files = FileManager.default
        guard BundleTransaction.exists(file) else { return }
        let record = try PropertyListDecoder().decode(RestoreRecord.self, from: Data(contentsOf: file))
        let allowed = try destinations(id, paths).map { $0.standardizedFileURL.path }
        var seen: Set<String> = []
        for item in record.items {
            let target = item.target.standardizedFileURL, parent = target.deletingLastPathComponent()
            guard item.target.isFileURL, item.staged.isFileURL, item.backup.isFileURL,
                  allowed.contains(target.path), seen.insert(target.path).inserted,
                  item.staged.standardizedFileURL.deletingLastPathComponent().path == parent.path,
                  item.backup.standardizedFileURL.deletingLastPathComponent().path == parent.path,
                  item.staged.lastPathComponent.hasPrefix(".mulg-restore-stage-"),
                  item.backup.lastPathComponent.hasPrefix(".mulg-restore-backup-") else { throw CocoaError(.fileReadCorruptFile) }
        }
        for item in record.items.reversed() {
            if record.committed || (item.hadTarget && !BundleTransaction.exists(item.backup)) {
                guard BundleTransaction.exists(item.target) else { throw CocoaError(.fileReadCorruptFile) }
            }
            if !record.committed {
                if BundleTransaction.exists(item.backup) {
                    if BundleTransaction.exists(item.target) { try files.removeItem(at: item.target) }
                    try BundleTransaction.move(item.backup, item.target)
                } else if !item.hadTarget && !BundleTransaction.exists(item.staged) && BundleTransaction.exists(item.target) {
                    try files.removeItem(at: item.target)
                }
            }
            for leftover in [item.staged, item.backup] where BundleTransaction.exists(leftover) { try files.removeItem(at: leftover) }
            try BundleTransaction.flush(item.target.deletingLastPathComponent())
        }
        try files.removeItem(at: file)
        try BundleTransaction.flush(file.deletingLastPathComponent())
    }
}
#endif
