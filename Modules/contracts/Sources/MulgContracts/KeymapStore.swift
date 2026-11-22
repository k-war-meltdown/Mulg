import Foundation

/// A game's keymaps on disk, compatible with upstream's layout:
/// `Keymapping/<bundle id>/.config.plist` plus one `<name>.plist` per keymap.
///
/// Upstream (Runtime/MulgKit/Keymap/Keymapping.swift) printed a literal "%@" and silently
/// reset keymaps it could not read. Here every problem is returned to the caller, and a keymap
/// that can't be read is never overwritten automatically, so the user's data is kept.
public struct KeymapStore: Sendable {
    public enum Problem: Error, Sendable, Equatable {
        case configUnreadable(String)
        case keymapUnreadable(file: String, reason: String)
        case keymapTooNew(file: String, version: String)
        case unwritable(file: String, reason: String)
    }

    public let folder: URL
    public let bundleIdentifier: String

    public init(paths: ContainerPaths, bundleIdentifier: String) {
        self.folder = paths.keymapDirectory(for: bundleIdentifier)
        self.bundleIdentifier = bundleIdentifier
    }

    public init(folder: URL, bundleIdentifier: String) {
        self.folder = folder
        self.bundleIdentifier = bundleIdentifier
    }

    public var configFile: URL {
        folder.appendingPathComponent(".config").appendingPathExtension("plist")
    }

    public func keymapFile(named name: String) -> URL {
        folder.appendingPathComponent(name).appendingPathExtension("plist")
    }

    public struct Loaded: Sendable {
        /// The keymap to use: the default one, or an empty keymap when none could be read.
        public let keymap: KeymappingData
        public let file: URL
        public let problems: [Problem]
    }

    /// Reads existing storage without repairing it. Only a new keymap list is initialized.
    public func loadDefault() -> Loaded {
        var problems: [Problem] = []
        let config: KeymapConfig
        switch readConfig() {
        case .success(let existing):
            config = existing
        case .failure(let problem):
            if FileManager.default.fileExists(atPath: configFile.path) {
                problems.append(problem)
                return Loaded(keymap: KeymappingData(bundleIdentifier: bundleIdentifier),
                              file: keymapFile(named: "default"), problems: problems)
            }
            let files = orderedKeymapFiles()
            let fallback = keymapFile(named: "default")
            config = KeymapConfig(defaultKm: files.contains(fallback) ? fallback : files.first ?? fallback,
                                  keymapOrder: files.isEmpty ? [fallback] : files)
            if files.isEmpty, let problem = write(KeymappingData(bundleIdentifier: bundleIdentifier), to: fallback) {
                problems.append(problem)
            }
            if let problem = writeConfig(config) { problems.append(problem) }
        }

        // Stored URLs may point at an old home folder; keep only the file name.
        let file = keymapFile(named: config.defaultKm.deletingPathExtension().lastPathComponent)
        if !FileManager.default.fileExists(atPath: file.path) {
            problems.append(.keymapUnreadable(file: file.path, reason: "The default keymap is missing."))
            return Loaded(keymap: KeymappingData(bundleIdentifier: bundleIdentifier), file: file, problems: problems)
        }

        switch read(file) {
        case .success(let keymap):
            if !keymap.isSupportedVersion {
                problems.append(.keymapTooNew(file: file.path, version: keymap.version))
                return Loaded(keymap: KeymappingData(bundleIdentifier: bundleIdentifier), file: file, problems: problems)
            }
            return Loaded(keymap: keymap, file: file, problems: problems)
        case .failure(let problem):
            problems.append(problem)
            return Loaded(keymap: KeymappingData(bundleIdentifier: bundleIdentifier), file: file, problems: problems)
        }
    }

    /// Resolves a touch-capable profile without overwriting the user's selected native profile.
    /// Switching the input mode back to touch must not leave an empty native-only map active.
    public func loadTouchDefault() -> Loaded {
        let selected = loadDefault()
        guard selected.problems.isEmpty, !selected.keymap.hasTouchControls else { return selected }
        for file in orderedKeymapFiles() {
            let candidate = load(file)
            if candidate.problems.isEmpty, candidate.keymap.bundleIdentifier == bundleIdentifier,
               candidate.keymap.hasTouchControls { return candidate }
        }
        return Loaded(keymap: selected.keymap, file: selected.file,
            problems: [.keymapUnreadable(file: selected.file.path,
                reason: "No touchscreen keymap is available. Import or create one in Keymaps.")])
    }

    /// The game's keymaps in the order the player arranged them (the config's order), then any
    /// other keymap files in the folder by name. Stored paths are re-rooted in this folder, and
    /// missing files are skipped.
    ///
    /// Upstream kept the keymaps in a dictionary, whose order is random, so "next keymap" went
    /// to a random one and the index it saved pointed at the wrong file.
    public func orderedKeymapFiles() -> [URL] {
        var names: [String] = []
        if case .success(let config) = readConfig() {
            for url in config.keymapOrder {
                let name = url.deletingPathExtension().lastPathComponent
                if !names.contains(name) { names.append(name) }
            }
        }
        let others = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".plist") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(".plist".count)) }
            .filter { !names.contains($0) }
            .sorted()
        return (names + others).map(keymapFile(named:)).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The keymap `offset` places away from `current` in `orderedKeymapFiles()`, wrapping around.
    public func keymapFile(offset: Int, from current: URL) -> URL? {
        let files = orderedKeymapFiles()
        guard !files.isEmpty else { return nil }
        let currentName = current.deletingPathExtension().lastPathComponent
        let index = files.firstIndex { $0.deletingPathExtension().lastPathComponent == currentName } ?? 0
        return files[((index + offset) % files.count + files.count) % files.count]
    }

    /// Loads one keymap file, refusing keymaps written by a newer format as `loadDefault` does.
    public func load(_ file: URL) -> Loaded {
        switch read(file) {
        case .success(let keymap) where keymap.isSupportedVersion:
            return Loaded(keymap: keymap, file: file, problems: [])
        case .success(let keymap):
            return Loaded(keymap: KeymappingData(bundleIdentifier: bundleIdentifier), file: file,
                          problems: [.keymapTooNew(file: file.path, version: keymap.version)])
        case .failure(let problem):
            return Loaded(keymap: KeymappingData(bundleIdentifier: bundleIdentifier), file: file, problems: [problem])
        }
    }

    public func read(_ file: URL) -> Result<KeymappingData, Problem> {
        do {
            let data = try Data(contentsOf: file)
            return .success(try PropertyListDecoder().decode(KeymappingData.self, from: data))
        } catch {
            return .failure(.keymapUnreadable(file: file.path, reason: String(describing: error)))
        }
    }

    public func readConfig() -> Result<KeymapConfig, Problem> {
        do {
            let data = try Data(contentsOf: configFile)
            return .success(try PropertyListDecoder().decode(KeymapConfig.self, from: data))
        } catch {
            return .failure(.configUnreadable(String(describing: error)))
        }
    }

    /// Writes a keymap as an XML property list, like upstream. Returns a problem on failure.
    @discardableResult
    public func write(_ keymap: KeymappingData, to file: URL, replacingUnreadable: Bool = false) -> Problem? {
        if FileManager.default.fileExists(atPath: file.path) {
            switch read(file) {
            case .success(let existing) where !existing.isSupportedVersion:
                return .keymapTooNew(file: file.path, version: existing.version)
            case .failure(let problem) where !replacingUnreadable: return problem
            default: break
            }
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            try encoder.encode(keymap).writeBeside(to: file)
            return nil
        } catch {
            return .unwritable(file: file.path, reason: String(describing: error))
        }
    }

    @discardableResult
    public func writeConfig(_ config: KeymapConfig, replacingUnreadable: Bool = false) -> Problem? {
        if !replacingUnreadable, FileManager.default.fileExists(atPath: configFile.path),
           case .failure(let problem) = readConfig() { return problem }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            try encoder.encode(config).writeBeside(to: configFile)
            return nil
        } catch {
            return .unwritable(file: configFile.path, reason: String(describing: error))
        }
    }

    // MARK: - Profiles (the in-game mapper)

    /// A profile is one keymap file. Its name is the file's name without `.plist`.
    public func profileName(of file: URL) -> String {
        file.deletingPathExtension().lastPathComponent
    }

    /// The game's profile names, in the order the player arranged them.
    public func profileNames() -> [String] {
        orderedKeymapFiles().map(profileName(of:))
    }

    /// A name safe to use as a file name: trimmed, without path separators, colons or control
    /// characters, not starting with a dot, at most 60 characters. Nil when nothing is left.
    public static func sanitizedProfileName(_ raw: String) -> String? {
        let forbidden = CharacterSet(charactersIn: "/\\:\u{0}").union(.controlCharacters).union(.newlines)
        let cleaned = raw.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        var name = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.prefix(60)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// `base`, or `base 2`, `base 3` … when a profile of that name exists (file names are not
    /// case-sensitive on the Mac).
    public func availableProfileName(_ base: String) -> String {
        let taken = Set(profileNames().map { $0.lowercased() })
        let root = Self.sanitizedProfileName(base) ?? "Controls"
        if !taken.contains(root.lowercased()) { return root }
        var number = 2
        while taken.contains("\(root) \(number)".lowercased()) { number += 1 }
        return "\(root) \(number)"
    }

    /// Creates a new profile file, never replacing an existing one. The name is made unique.
    public func createProfile(named base: String, keymap: KeymappingData) -> Result<URL, Problem> {
        let file = keymapFile(named: availableProfileName(base))
        if let problem = write(keymap, to: file) { return .failure(problem) }
        if case .success(var config) = readConfig() {
            if !config.keymapOrder.contains(where: { profileName(of: $0) == profileName(of: file) }) {
                config.keymapOrder.append(file)
                if let problem = writeConfig(config) { return .failure(problem) }
            }
        }
        return .success(file)
    }

    /// Makes `file` the profile used the next time the game starts, and puts it in the order if it
    /// is not there yet. Nothing in any keymap file changes. An unreadable config is left alone.
    @discardableResult
    public func makeDefault(_ file: URL) -> Problem? {
        guard case .success(var config) = readConfig() else {
            if FileManager.default.fileExists(atPath: configFile.path), case .failure(let problem) = readConfig() { return problem }
            return writeConfig(KeymapConfig(defaultKm: file, keymapOrder: orderedKeymapFiles().isEmpty ? [file] : orderedKeymapFiles()))
        }
        let name = profileName(of: file)
        guard config.defaultKm.deletingPathExtension().lastPathComponent != name
                || !config.keymapOrder.contains(where: { profileName(of: $0) == name }) else { return nil }
        config.defaultKm = file
        if !config.keymapOrder.contains(where: { profileName(of: $0) == name }) { config.keymapOrder.append(file) }
        return writeConfig(config)
    }

    /// Keeps a copy of `file` before it is overwritten, in `.backups/`, newest `keeping` per
    /// profile. A profile that does not exist yet has nothing to back up.
    @discardableResult
    public func backUp(_ file: URL, keeping: Int = 5, now: Date = Date()) -> Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: file.path) else { return true }
        let backups = folder.appendingPathComponent(".backups", isDirectory: true)
        let name = profileName(of: file)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        do {
            try files.createDirectory(at: backups, withIntermediateDirectories: true)
            let copy = backups.appendingPathComponent("\(name) \(stamp)").appendingPathExtension("plist")
            if files.fileExists(atPath: copy.path) { try files.removeItem(at: copy) }
            try files.copyItem(at: file, to: copy)
            let mine = ((try? files.contentsOfDirectory(atPath: backups.path)) ?? [])
                // Exactly "<name> <20-character stamp>.plist": another profile whose name starts
                // with this one's ("Star Rail (adaptive)") is not counted.
                .filter { $0.hasPrefix(name + " ") && $0.hasSuffix(".plist") && $0.count == name.count + 1 + 20 + 6 }.sorted()
            for old in mine.dropLast(max(1, keeping)) { try? files.removeItem(at: backups.appendingPathComponent(old)) }
            return true
        } catch {
            return false
        }
    }
}
