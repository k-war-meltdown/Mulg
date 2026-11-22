import Foundation
import Darwin

/// Why a settings file could not be read or written.
public enum SettingsStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case unreadable(file: String, reason: String)
    case unwritable(file: String, reason: String)

    public var description: String {
        switch self {
        case let .unreadable(file, reason): "Could not read settings at \(file): \(reason)"
        case let .unwritable(file, reason): "Could not write settings at \(file): \(reason)"
        }
    }
}

/// Reads and writes per-game settings files.
///
/// Upstream MulgKit silently falls back to defaults when a file can't be decoded
/// (`MulgKitSettings.swift:22` prints a literal `%@` and drops the error). Here the caller
/// always learns about the problem and can tell the user (PLAN.md §6, §12).
public struct SettingsStore: Sendable {
    public let paths: ContainerPaths

    public init(paths: ContainerPaths = .current()) {
        self.paths = paths
    }

    /// The result of loading: the settings to use, plus any problem that forced defaults.
    public struct LoadResult: Sendable {
        public let settings: GameSettings
        public let problem: SettingsStoreError?
    }

    /// Loads a game's settings. A missing file is normal (new game) and gives defaults
    /// without a problem; an unreadable file gives defaults and reports why.
    public func load(bundleIdentifier: String) -> LoadResult {
        let file = paths.settingsFile(for: bundleIdentifier)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return LoadResult(settings: GameSettings(bundleIdentifier: bundleIdentifier), problem: nil)
        }
        do {
            let data = try Data(contentsOf: file)
            var settings = try Self.decode(data)
            // The file's location decides its owner; a copied plist must not write back to
            // another game's settings file when the runtime saves a change.
            settings.bundleIdentifier = bundleIdentifier
            return LoadResult(settings: settings, problem: nil)
        } catch {
            return LoadResult(
                settings: GameSettings(bundleIdentifier: bundleIdentifier),
                problem: .unreadable(file: file.path, reason: String(describing: error))
            )
        }
    }

    /// Writes a game's settings as an XML property list, like upstream Mulg.
    public func save(_ settings: GameSettings) throws(SettingsStoreError) {
        try withLock(bundleIdentifier: settings.bundleIdentifier) { () throws(SettingsStoreError) in
            try write(settings)
        }
    }

    /// Merge and write under one process-shared lock; atomic replacement alone loses concurrent edits.
    @discardableResult
    public func save(_ edited: GameSettings, basedOn base: GameSettings) throws(SettingsStoreError) -> GameSettings {
        try withLock(bundleIdentifier: edited.bundleIdentifier) { () throws(SettingsStoreError) in
            let current = load(bundleIdentifier: edited.bundleIdentifier)
            if let problem = current.problem { throw problem }
            let merged = Self.merge(base: base, edited: edited, onto: current.settings)
            try write(merged)
            recordSandboxPolicy(base: SandboxPolicy(base), edited: SandboxPolicy(edited), bundleIdentifier: edited.bundleIdentifier)
            return merged
        }
    }

    private func withLock<T>(bundleIdentifier: String, _ body: () throws(SettingsStoreError) -> T) throws(SettingsStoreError) -> T {
        do { return try withExclusiveAccess(bundleIdentifier: bundleIdentifier, body) }
        catch let error as SettingsStoreError { throw error }
        catch { throw .unwritable(file: paths.settingsFile(for: bundleIdentifier).path, reason: String(describing: error)) }
    }

    /// Shared by host restore and all settings writers. Caller must not recursively take this lock.
    public func withExclusiveAccess<T>(bundleIdentifier: String, _ body: () throws -> T) throws -> T {
        let file = paths.settingsFile(for: bundleIdentifier)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw SettingsStoreError.unwritable(file: file.path, reason: error.localizedDescription)
        }
        let descriptor = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SettingsStoreError.unwritable(file: file.path, reason: String(cString: strerror(errno))) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw SettingsStoreError.unwritable(file: file.path, reason: String(cString: strerror(errno))) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// The legacy host schema shares the same file and lock, but must retain keys it cannot decode.
    public func saveLegacy(_ edited: Data, basedOn base: Data?, bundleIdentifier: String,
                           reset: Bool = false) throws(SettingsStoreError) -> Data {
        try withLock(bundleIdentifier: bundleIdentifier) { () throws(SettingsStoreError) -> Data in
            let file = paths.settingsFile(for: bundleIdentifier)
            do {
                func tree(_ data: Data) throws -> [String: Any] {
                    guard let tree = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                    else { throw CocoaError(.propertyListReadCorrupt) }
                    return tree
                }
                let fresh = try tree(edited)
                let baseTree = try base.map { try tree($0) }
                var current = reset || !FileManager.default.fileExists(atPath: file.path)
                    ? fresh : try tree(Data(contentsOf: file))
                if !reset { Self.apply(baseTree ?? [:], fresh, to: &current) }
                let result = try PropertyListSerialization.data(fromPropertyList: current, format: .xml, options: 0)
                try result.writeBeside(to: file)
                recordSandboxPolicy(base: reset ? nil : baseTree.map(SandboxPolicy.init(tree:)),
                                    edited: SandboxPolicy(tree: fresh), bundleIdentifier: bundleIdentifier)
                return result
            } catch {
                throw .unwritable(file: file.path, reason: String(describing: error))
            }
        }
    }

    /// The app's own saves record the sandbox choices the player changed (SandboxPolicy). The game's
    /// runtime (Mac Catalyst) never does: its sandbox would refuse, and its writes must never count.
    private func recordSandboxPolicy(base: SandboxPolicy?, edited: SandboxPolicy, bundleIdentifier: String) {
        #if os(macOS) && !targetEnvironment(macCatalyst)
        try? SandboxPolicy.record(base: base, edited: edited, for: bundleIdentifier, paths: paths)
        #endif
    }

    private func write(_ settings: GameSettings) throws(SettingsStoreError) {
        let file = paths.settingsFile(for: settings.bundleIdentifier)
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encode(settings).writeBeside(to: file)
        } catch {
            throw SettingsStoreError.unwritable(file: file.path, reason: String(describing: error))
        }
    }

    /// For a screen that saves a whole snapshot: the values `edited` changed from `base` (what
    /// the screen loaded) are applied to `current` (the file now), so a newer change another
    /// window or the running game made to a different value survives. Dictionaries merge key
    /// by key; any other value is replaced whole. If the settings cannot be encoded, `edited`.
    public static func merge(base: GameSettings, edited: GameSettings, onto current: GameSettings) -> GameSettings {
        func tree(_ settings: GameSettings) throws -> [String: Any] {
            try PropertyListSerialization.propertyList(from: encode(settings), format: nil) as? [String: Any] ?? [:]
        }
        do {
            var merged = try tree(current)
            apply(try tree(base), try tree(edited), to: &merged)
            var result = try decode(PropertyListSerialization.data(fromPropertyList: merged, format: .xml, options: 0))
            result.bundleIdentifier = edited.bundleIdentifier
            return result
        } catch {
            return edited
        }
    }

    private static func apply(_ base: [String: Any], _ edited: [String: Any], to current: inout [String: Any]) {
        func same(_ a: Any?, _ b: Any?) -> Bool {
            switch (a, b) {
            case (nil, nil): true
            case let (a?, b?): (a as AnyObject).isEqual(b)
            default: false
            }
        }
        for key in Set(base.keys).union(edited.keys) {
            if let old = base[key] as? [String: Any], let new = edited[key] as? [String: Any],
               var now = current[key] as? [String: Any] {
                apply(old, new, to: &now)
                current[key] = now
            } else if !same(base[key], edited[key]) {
                current[key] = edited[key]
            }
        }
    }

    public static func decode(_ data: Data) throws -> GameSettings {
        try PropertyListDecoder().decode(GameSettings.self, from: data)
    }

    public static func encode(_ settings: GameSettings) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return try encoder.encode(settings)
    }
}
