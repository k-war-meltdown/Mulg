#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Security
import MulgContracts
import Darwin

/// One persisted replacement, shared by installs and runtime refreshes. Callers hold the
/// game's session lease. A surviving record is rolled back before another launch or update.
public enum BundleTransaction {
    struct Companion: Codable {
        let target: URL
        let staged: URL
        let backup: URL
        let hadTarget: Bool
    }
    struct Record: Codable {
        let bundleIdentifier: String
        let target: URL
        let staged: URL
        let backup: URL
        let link: URL?
        let linkBackup: URL?
        let hadTarget: Bool
        let hadLink: Bool
        var committed = false
        var companions: [Companion]? = nil // Absent in older recovery records.
    }

    static func folder(_ paths: ContainerPaths) -> URL { paths.mulgStateDirectory.appendingPathComponent("BundleTransactions") }
    static func journal(_ id: String, _ paths: ContainerPaths) -> URL { folder(paths).appendingPathComponent(id + ".json") }
    static func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }

    public static func copy(_ source: URL, to target: URL) throws {
        let parent = target.deletingLastPathComponent()
        if try parent.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == false
            || source.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == false {
            // SMB servers may reject the ACLs and extended attributes that copyItem carries
            // across from local storage. Code signatures live in the bundle's regular files.
            guard !exists(target) else { throw CocoaError(.fileWriteFileExists) }
            try Command.run("/usr/bin/ditto", ["--norsrc", "--noextattr", "--noacl", source.path, target.path])
        } else {
            try FileManager.default.copyItem(at: source, to: target)
        }
    }

    public static func workingDirectory(for app: URL) throws -> URL {
        let files = FileManager.default
        if try app.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == false {
            let directory = files.temporaryDirectory.appendingPathComponent("Mulg-Edit-" + UUID().uuidString)
            try files.createDirectory(at: directory, withIntermediateDirectories: false)
            return directory
        }
        return try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
    }

    public static func hasPendingRecovery(_ id: String, paths: ContainerPaths = .current()) -> Bool {
        GameSessionLease.isValidBundleIdentifier(id) && exists(journal(id, paths))
    }

    public static func flush(_ url: URL, full: Bool = false) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // External volumes may support fsync without a full-device barrier.
        if full && fcntl(fd, F_FULLFSYNC) != 0 && errno != ENOTSUP && errno != EINVAL {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func save(_ record: Record, paths: ContainerPaths) throws {
        try FileManager.default.createDirectory(at: folder(paths), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = journal(record.bundleIdentifier, paths)
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try flush(file, full: true)
        try flush(folder(paths))
    }

    static func move(_ source: URL, _ target: URL) throws {
        try FileManager.default.moveItem(at: source, to: target)
        try flush(target.deletingLastPathComponent())
    }

    static func flushTree(_ root: URL) throws {
        if let children = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) {
            for case let file as URL in children {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                if (values.isRegularFile == true || values.isDirectory == true) && values.isSymbolicLink != true { try flush(file) }
            }
        }
        try flush(root)
        try flush(root.deletingLastPathComponent())
    }

    public static func replace(_ source: URL, at target: URL, bundleIdentifier: String,
                               link: URL? = nil, paths: ContainerPaths = .current(),
                               companions: [URL: URL] = [:],
                               verify: (URL) throws -> Void = verifySignature) throws {
        // Validate journal names using the same contract as the already-held session lease.
        guard GameSessionLease.isValidBundleIdentifier(bundleIdentifier) else { throw CocoaError(.fileWriteInvalidFileName) }
        try recover(bundleIdentifier, paths: paths, verify: verify)
        let parent = target.deletingLastPathComponent()
        let token = UUID().uuidString
        let staged = parent.appendingPathComponent(".mulg-stage-\(token).app")
        let backup = parent.appendingPathComponent(".mulg-backup-\(token).app")
        let separateLink = link?.standardizedFileURL == target.standardizedFileURL ? nil : link
        let linkBackup = separateLink?.deletingLastPathComponent().appendingPathComponent(".mulg-link-\(token).app")
        let files = FileManager.default
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        if let separateLink { try files.createDirectory(at: separateLink.deletingLastPathComponent(), withIntermediateDirectories: true) }
        defer { if !exists(journal(bundleIdentifier, paths)) { try? files.removeItem(at: staged) } }
        try copy(source, to: staged)
        try verify(staged)
        // Flush staged contents before publishing the recovery record, then flush its directory.
        try flushTree(staged)
        var record = Record(bundleIdentifier: bundleIdentifier, target: target, staged: staged, backup: backup,
                            link: separateLink, linkBackup: linkBackup, hadTarget: exists(target),
                            hadLink: separateLink.map(exists) ?? false)
        record.companions = []
        defer {
            if !exists(journal(bundleIdentifier, paths)) {
                for item in record.companions ?? [] { try? files.removeItem(at: item.staged) }
            }
        }
        for (destination, source) in companions.sorted(by: { $0.key.path < $1.key.path }) {
            let parent = destination.deletingLastPathComponent()
            try files.createDirectory(at: parent, withIntermediateDirectories: true)
            let staged = parent.appendingPathComponent(".mulg-companion-stage-" + token)
            record.companions?.append(Companion(target: destination, staged: staged,
                             backup: parent.appendingPathComponent(".mulg-companion-backup-" + token),
                             hadTarget: exists(destination)))
            try copy(source, to: staged)
            try flushTree(staged)
        }
        try validate(record, id: bundleIdentifier)
        try save(record, paths: paths)
        do {
            if record.hadTarget { try move(target, backup) }
            try move(staged, target)
            try verify(target)
            for item in record.companions ?? [] {
                if item.hadTarget { try move(item.target, item.backup) }
                try move(item.staged, item.target)
            }
            if let separateLink, let linkBackup {
                if record.hadLink { try move(separateLink, linkBackup) }
                try files.createSymbolicLink(at: separateLink, withDestinationURL: target)
                try flush(separateLink.deletingLastPathComponent())
            }
            record.committed = true
            try save(record, paths: paths)
        } catch {
            // If rollback itself fails, retain the record and all backups for the next start.
            try recover(bundleIdentifier, paths: paths, verify: verify)
            throw error
        }
        try recover(bundleIdentifier, paths: paths, verify: verify)
    }

    static func validate(_ record: Record, id: String) throws {
        let parent = record.target.deletingLastPathComponent().standardizedFileURL
        guard record.bundleIdentifier == id, record.target.isFileURL,
              record.target.lastPathComponent == id + ".app", record.staged.isFileURL, record.backup.isFileURL,
              record.staged.deletingLastPathComponent().standardizedFileURL == parent,
              record.backup.deletingLastPathComponent().standardizedFileURL == parent,
              record.staged.lastPathComponent.hasPrefix(".mulg-stage-"),
              record.backup.lastPathComponent.hasPrefix(".mulg-backup-") else { throw CocoaError(.fileReadCorruptFile) }
        if let link = record.link, let backup = record.linkBackup {
            guard link.isFileURL, backup.isFileURL, link.lastPathComponent == id + ".app",
                  backup.deletingLastPathComponent().standardizedFileURL == link.deletingLastPathComponent().standardizedFileURL,
                  backup.lastPathComponent.hasPrefix(".mulg-link-") else { throw CocoaError(.fileReadCorruptFile) }
        } else if record.link != nil || record.linkBackup != nil { throw CocoaError(.fileReadCorruptFile) }
        for item in record.companions ?? [] {
            let parent = item.target.deletingLastPathComponent().standardizedFileURL
            guard item.target.isFileURL, item.target.lastPathComponent == id,
                  item.staged.isFileURL, item.backup.isFileURL,
                  item.staged.deletingLastPathComponent().standardizedFileURL == parent,
                  item.backup.deletingLastPathComponent().standardizedFileURL == parent,
                  item.staged.lastPathComponent.hasPrefix(".mulg-companion-stage-"),
                  item.backup.lastPathComponent.hasPrefix(".mulg-companion-backup-") else { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    /// Recover one game while its caller holds the lease; never silently discard a bad journal.
    public static func recover(_ id: String, paths: ContainerPaths = .current(),
                               remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
                               verify: (URL) throws -> Void = verifySignature) throws {
        guard GameSessionLease.isValidBundleIdentifier(id) else { throw GameSessionLease.Failure.invalidIdentifier }
        try retryCleanup(id, paths: paths, remove: remove)
        let file = journal(id, paths)
        guard exists(file) else { return }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
        try validate(record, id: id)
        let files = FileManager.default
        if record.committed {
            try verify(record.target)
            if let link = record.link {
                guard try files.destinationOfSymbolicLink(atPath: link.path) == record.target.path else { throw CocoaError(.fileReadCorruptFile) }
            }
            for item in record.companions ?? [] where !exists(item.target) { throw CocoaError(.fileReadCorruptFile) }
        } else {
            for item in record.companions ?? [] {
                if exists(item.backup) {
                    if exists(item.target) { try files.removeItem(at: item.target) }
                    try move(item.backup, item.target)
                } else if !item.hadTarget && exists(item.target) { try files.removeItem(at: item.target) }
            }
            if exists(record.backup) {
                try verify(record.backup)
                if exists(record.target) { try files.removeItem(at: record.target) }
                try move(record.backup, record.target)
            } else if record.hadTarget {
                try verify(record.target) // Replacement had not started, or rollback already restored it.
            } else if exists(record.target) {
                try files.removeItem(at: record.target)
                try flush(record.target.deletingLastPathComponent())
            }
            if let link = record.link, let backup = record.linkBackup {
                if exists(backup) {
                    if exists(link) { try files.removeItem(at: link) }
                    try move(backup, link)
                } else if !record.hadLink && exists(link) { try files.removeItem(at: link) }
            }
        }
        do {
            try discardArtifacts(record, remove: remove)
        } catch {
            guard record.committed, canDeferCleanup(error) else { throw error }
            // Verification above already proved the new bundle and companion publication.
            // Keep a separate durable cleanup record before releasing the active transaction;
            // an SMB sharing/permission failure on old bytes must not block game startup.
            let queue = cleanupFolder(paths)
            try files.createDirectory(at: queue, withIntermediateDirectories: true)
            let pending = queue.appendingPathComponent(id + ".cleanup-" + UUID().uuidString + ".json")
            try JSONEncoder().encode(record).write(to: pending, options: .atomic)
            try flush(pending, full: true)
            try flush(queue)
        }
        try flush(record.target.deletingLastPathComponent())
        try files.removeItem(at: file)
        try flush(folder(paths))
    }

    static func cleanupFolder(_ paths: ContainerPaths) -> URL { paths.mulgStateDirectory.appendingPathComponent("BundleCleanup") }

    static func canDeferCleanup(_ error: any Error) -> Bool {
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(value.code) { return true }
        if value.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM), Int(EBUSY), Int(ETXTBSY)].contains(value.code) { return true }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError { return canDeferCleanup(underlying) }
        return false
    }

    static func discardArtifacts(_ record: Record, remove: (URL) throws -> Void) throws {
        let companions = record.companions ?? []
        let stale = companions.flatMap { [$0.backup, $0.staged] }
            + [record.backup, record.staged] + [record.linkBackup].compactMap { $0 }
        for item in stale where exists(item) { try remove(item) }
        for item in companions { try flush(item.target.deletingLastPathComponent()) }
    }

    /// Called under the game lease. Strict cleanup is required for a complete uninstall;
    /// ordinary launches retry transient SMB failures without losing their cleanup records.
    public static func retryCleanup(_ id: String, paths: ContainerPaths = .current(), strict: Bool = false,
                                    remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        guard GameSessionLease.isValidBundleIdentifier(id) else { throw GameSessionLease.Failure.invalidIdentifier }
        let files = FileManager.default, queue = cleanupFolder(paths)
        guard exists(queue) else { return }
        for file in try files.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix(id + ".cleanup-") && file.pathExtension == "json" {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
            try validate(record, id: id)
            guard record.committed else { throw CocoaError(.fileReadCorruptFile) }
            do {
                try discardArtifacts(record, remove: remove)
                try flush(record.target.deletingLastPathComponent())
                try files.removeItem(at: file)
                try flush(queue)
            } catch {
                if strict || !canDeferCleanup(error) { throw error }
            }
        }
    }

    /// Run at host startup. Running games are skipped; their launch path retries under a lease.
    public static func recoverPending(paths: ContainerPaths = .current()) throws {
        let files = try? FileManager.default.contentsOfDirectory(at: folder(paths), includingPropertiesForKeys: nil)
        var failure: (any Error)?
        for file in files ?? [] where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            do {
                let lease = try GameSessionLease(bundleIdentifier: id, paths: paths)
                defer { withExtendedLifetime(lease) {} }
                try recover(id, paths: paths)
            } catch GameSessionLease.Failure.busy { continue }
            catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
    }

    public static func verifySignature(_ app: URL) throws {
        if try app.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == false {
            // Validate the bytes read back from the server. Some SMB implementations expose
            // synthetic Finder/resource-fork metadata even after a metadata-free copy.
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("Mulg-Verify-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let local = scratch.appendingPathComponent(app.lastPathComponent)
            try Command.run("/usr/bin/ditto", ["--norsrc", "--noextattr", "--noacl", app.path, local.path])
            try Command.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", local.path])
        } else {
            try verifyCode(app)
        }
    }

    public struct CodeSignatureFailure: Error, Sendable, CustomStringConvertible {
        public let path: String
        public let status: OSStatus
        public var description: String { "The code signature of \(path) is not valid (\(status))." }
    }

    /// Checks the signed code of `app` and of every framework, library and plug-in inside it, in
    /// process and strictly, but does not hash the resources again: signing has just sealed them,
    /// and a game's resources are often gigabytes. A damaged or unsigned binary still fails.
    public static func verifyCode(_ app: URL) throws {
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSStrictValidate)
        let files = FileManager.default
        var items = [app]
        for folder in ["Frameworks", "PlugIns", "Extensions"] {
            let directory = app.appendingPathComponent(folder)
            for name in (try? files.contentsOfDirectory(atPath: directory.path)) ?? []
            where ["framework", "dylib", "bundle", "appex"].contains((name as NSString).pathExtension) {
                items.append(directory.appendingPathComponent(name))
            }
        }
        for item in items {
            var code: SecStaticCode?
            var status = SecStaticCodeCreateWithPath(item as CFURL, [], &code)
            if status == errSecSuccess, let code { status = SecStaticCodeCheckValidity(code, flags, nil) }
            guard status == errSecSuccess else { throw CodeSignatureFailure(path: item.path, status: status) }
        }
    }
}
#endif
