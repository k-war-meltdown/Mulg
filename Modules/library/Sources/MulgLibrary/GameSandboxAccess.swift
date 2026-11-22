import Foundation
import MulgContracts

/// What one game may reach outside its own container (2026-10-10 sandbox hardening). Games used to get
/// read-write access to all of Mulg's data (every game's login database, settings and keymaps) and read
/// access to every app's Group Containers on the Mac. Now each game gets only its own files in Mulg's
/// folder and its own app groups; macOS enforces this in the game's sandbox, whatever code it runs.
public enum GameSandboxAccess {
    /// Mulg's per-game paths. `file`: the path itself and the few names derived from it (`fileSuffixes`).
    /// `folder`: that folder and below.
    enum Grant: Equatable {
        case file(URL)
        case folder(URL)
        case readOnlyFolder(URL)

        var canonical: Grant {
            switch self {
            case .file(let url): .file(GameSandboxAccess.canonical(url))
            case .folder(let url): .folder(GameSandboxAccess.canonical(url))
            case .readOnlyFolder(let url): .readOnlyFolder(GameSandboxAccess.canonical(url))
            }
        }
    }

    static func grants(for id: String, paths: ContainerPaths) -> [Grant] {
        let state = paths.mulgStateDirectory
        return [
            .file(paths.settingsFile(for: id)),
            .folder(paths.keymapDirectory(for: id)),
            .file(paths.mulgChainDatabase(for: id)),
            .file(paths.mulgChainDirectory.appendingPathComponent(id + "." + ContainerPaths.legacyVaultExtension)),
            .file(paths.mulgChainKey(for: id)),
            .file(paths.safeModeMarker(for: id)),
            .file(paths.safeModeMarker(for: id).appendingPathExtension("last.json")),
            .file(state.appendingPathComponent("Sessions").appendingPathComponent(id + ".lock")),
            .file(state.appendingPathComponent("Sessions").appendingPathComponent(id + ".launch.lock")),
            .folder(paths.diagnosticsDirectory(for: id)),
            .folder(paths.shaderArchiveDirectory(for: id)),
            .file(paths.cameraCalibrationFile(for: id)),
            .file(state.appendingPathComponent("DataLocations").appendingPathComponent(id + ".json")),
            // Shared by every game on purpose: the audio-device locks coordinate games with each other. They
            // hold no data; a game misusing them can at most keep another from changing a device's format.
            .folder(paths.audioOutputLockDirectory),
            .readOnlyFolder(paths.applicationsDirectory.appendingPathComponent(id + ".app")),
        ]
    }

    /// SBPL for the game: its own files in Mulg's folder, the settings folder's listing (the runtime
    /// watches it for changes; it shows file names only), and the folders above each grant for lookups.
    /// Nil for an identifier that could not be a bundle ID, so no rule is ever built from a hostile one.
    public static func sandboxRules(for id: String, paths: ContainerPaths = .current()) -> [String]? {
        guard GameSessionLease.isValidBundleIdentifier(id) else { return nil }
        var rules: [String] = []
        for grant in grants(for: id, paths: paths) {
            switch grant.canonical {
            case .file(let url):
                rules.append("(allow file* (regex #\"^\(regexEscape(url.path))\(fileSuffixes)$\"))")
                rules.append("(allow file-read-metadata (path-ancestors \(quote(url.deletingLastPathComponent().path))))")
            case .folder(let url):
                rules.append("(allow file* (subpath \(quote(url.path))))")
                rules.append("(allow file-read-metadata (path-ancestors \(quote(url.path))))")
            case .readOnlyFolder(let url):
                rules.append("(allow file-read* (subpath \(quote(url.path))))")
                rules.append("(allow file-read-metadata (path-ancestors \(quote(url.path))))")
            }
        }
        rules.append("(allow file-read* (literal \(quote(canonical(paths.appSettingsDirectory).path))))")
        // Code that makes sure a shared folder exists (createDirectory on an existing one) is asking to create
        // it: the folders themselves may be created, never a file in them that is not the game's own. Without
        // this the credential store, safe mode and session locks failed in every game (build 930, 2026-10-10).
        for folder in sharedFolders(for: id, paths: paths) {
            rules.append("(allow file-write-create (literal \(quote(canonical(folder).path))))")
        }
        return rules
    }

    /// What a granted file may also be called: its lock (`<id>.plist.lock`), the `.sb-…` temporary of an
    /// atomic save and SQLite's `-wal`/`-shm`/`-journal`. Anchored at both ends: a bare prefix let a game reach
    /// another game whose identifier merely starts the same way (`com.x.key` matched `com.x.keyboard.key`).
    static let fileSuffixes = #"(\.lock|\.sb-[^/]+|-wal|-shm|-journal)?"#

    /// The services behind the macOS Keychain, legacy login keychain and data-protection keychain alike, with
    /// iCloud Keychain sync and the "allow access" prompt. Certificate trust (trustd, so HTTPS works) and the
    /// Secure Enclave (ctkd, which opens the sealed keys) stay reachable. Measured on macOS 27 (2026-10-10):
    /// a process behind these rules sees none of the login keychain's items, the Enclave and HTTPS work.
    public static let keychainServices = [
        "com.apple.SecurityServer", "com.apple.securityd.xpc", "com.apple.securityd.general", "com.apple.securityd.sos",
        "com.apple.securityd.ckks", "com.apple.securityd.aps", "com.apple.security.octagon", "com.apple.security.kcsharing",
        "com.apple.security.escrow-update", "com.apple.security.agent", "com.apple.security.cloudkeychainproxy3",
        "com.apple.security.KeychainStasher", "com.apple.keychainsharingmessagingd",
    ]

    /// The keychain wall: the game can neither reach the Keychain services nor read the keychain files, whatever
    /// code it runs. Appended last, so no earlier allowance can reopen it.
    public static func keychainWallRules(home: URL) -> [String] {
        ["(deny mach-lookup " + keychainServices.map { "(global-name \(quote($0)))" }.joined(separator: " ") + ")",
         "(deny file* (subpath \(quote(canonical(home.appendingPathComponent("Library/Keychains")).path))))"]
    }

    /// One launch without the wall, so the game moves the database key an older Mulg kept in the Keychain into
    /// its sealed file (the item belongs to the game: Mulg itself would make macOS ask for the password). True
    /// while saved logins are on, a database exists and its key file does not, for ten minutes from the time it
    /// is granted. Afterwards the wall goes up whatever happened, and nothing is moved or deleted: a key that did
    /// not arrive leaves the database as it is, and the Privacy tab offers Clear saved logins (a bug once kept
    /// the key from arriving; logins must never vanish silently).
    ///
    /// A window opens only while `legacyKeyExists` finds the older key in the Keychain, and at most
    /// `maxMigrationWindows` times per game (a move cut short, by a declined macOS prompt or a game quit at once,
    /// gets another launch, but a game can never keep its wall down). The record lives where no game can reach
    /// it: the game can delete its own key file or create a database, and once could also delete the record.
    public static func keychainMigrationLaunch(for id: String, savesLogins: Bool, paths: ContainerPaths = .current(),
                                               now: Date = .now, legacyKeyExists: (String) -> Bool) -> Bool {
        switch migrationState(for: id, savesLogins: savesLogins, paths: paths, now: now) {
        case .notStarted:
            guard GameSessionLease.isValidBundleIdentifier(id) else { return false }
            let files = FileManager.default
            let marker = migrationMarker(for: id, paths: paths)
            try? files.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard legacyKeyExists(id) else {
                // Nothing to move: no window, now or later (the Privacy tab shows the logins as stuck).
                guard files.createFile(atPath: marker.path, contents: Data(String(maxMigrationWindows).utf8)) else { return false }
                try? files.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: marker.path)
                return false
            }
            let granted = migrationWindowsGranted(for: id, paths: paths) + 1
            guard files.createFile(atPath: marker.path, contents: Data(String(granted).utf8)) else { return false }
            try? files.setAttributes([.modificationDate: now], ofItemAtPath: marker.path)
            return true
        case .pending: return true
        case .none, .stuck, .waitingForUnlock: return false
        }
    }

    /// `waitingForUnlock`: the database is locked by the Mulg vault, so the game could not move its key now; the
    /// wall stays up (a locked game cannot use logins anyway) and the window opens once the vault is unlocked.
    public enum MigrationState: Equatable { case none, notStarted, pending, stuck, waitingForUnlock }

    /// Where the move of an older Keychain-held login key stands (also shown on the Privacy tab).
    public static func migrationState(for id: String, savesLogins: Bool, paths: ContainerPaths = .current(),
                                      now: Date = .now) -> MigrationState {
        let files = FileManager.default
        let database = paths.mulgChainDatabase(for: id)
        let locked = paths.mulgChainDirectory.appendingPathComponent(id + "." + ContainerPaths.legacyVaultExtension)
        guard savesLogins, !files.fileExists(atPath: paths.mulgChainKey(for: id).path),
              files.fileExists(atPath: database.path) || files.fileExists(atPath: locked.path) else { return .none }
        guard files.fileExists(atPath: database.path) else { return .waitingForUnlock }
        // Builds 930–931 kept the record beside the database, where the game could delete it: still honoured.
        let started = [migrationMarker(for: id, paths: paths), legacyMigrationMarker(for: id, paths: paths)].lazy
            .compactMap { (try? files.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }.first
        guard let started else { return .notStarted }
        if now.timeIntervalSince(started) < migrationWindow { return .pending }
        return migrationWindowsGranted(for: id, paths: paths) < maxMigrationWindows ? .notStarted : .stuck
    }

    /// In Mulg's state folder, which no game's sandbox grants. Holds how many windows were granted.
    static func migrationMarker(for id: String, paths: ContainerPaths) -> URL {
        paths.mulgStateDirectory.appendingPathComponent("KeychainMigration", isDirectory: true)
            .appendingPathComponent(id, isDirectory: false)
    }

    static func legacyMigrationMarker(for id: String, paths: ContainerPaths) -> URL {
        paths.mulgChainDirectory.appendingPathComponent(id + ".key-migration")
    }

    /// Windows granted so far: the record's count; an old 930–931 record counts as one.
    static func migrationWindowsGranted(for id: String, paths: ContainerPaths) -> Int {
        if let data = FileManager.default.contents(atPath: migrationMarker(for: id, paths: paths).path) {
            return Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        }
        return FileManager.default.fileExists(atPath: legacyMigrationMarker(for: id, paths: paths).path) ? 1 : 0
    }

    static let migrationWindow: TimeInterval = 600
    static let maxMigrationWindows = 3

    /// The shared folders above every grant, up to Mulg's own folder.
    static func sharedFolders(for id: String, paths: ContainerPaths) -> [URL] {
        let top = paths.mulgContainer.standardizedFileURL.path
        var folders: [URL] = []
        for grant in grants(for: id, paths: paths) {
            var folder: URL
            switch grant {
            case .file(let url): folder = url.deletingLastPathComponent()
            case .folder(let url), .readOnlyFolder(let url): folder = url.deletingLastPathComponent()
            }
            while folder.standardizedFileURL.path.hasPrefix(top) {
                if !folders.contains(folder) { folders.append(folder) }
                if folder.standardizedFileURL.path == top { break }
                folder = folder.deletingLastPathComponent()
            }
        }
        return folders
    }

    /// The folders the game writes into must exist first: its sandbox may create only its own entries.
    public static func prepareFolders(for id: String, paths: ContainerPaths = .current()) {
        guard GameSessionLease.isValidBundleIdentifier(id) else { return }
        let files = FileManager.default
        for grant in grants(for: id, paths: paths) {
            switch grant {
            case .file(let url): try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            case .folder(let url): try? files.createDirectory(at: url, withIntermediateDirectories: true)
            case .readOnlyFolder: break
            }
        }
        // The shared credential folder stays owner-only; games never change it themselves.
        try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.mulgChainDirectory.path)
    }

    /// The game's own app groups (`com.apple.security.application-groups` in its original entitlements),
    /// each only its own folder in Group Containers. Ad-hoc signing cannot keep the entitlement, so these
    /// rules replace it; every other app's group stays out of reach.
    public static func groupContainerRules(groups: [String], home: URL) -> [String] {
        let folder = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
        return groups.filter(isValidGroup).flatMap { group -> [String] in
            let path = folder.appendingPathComponent(group, isDirectory: true).path
            return ["(allow file* (subpath \(quote(path))))", "(allow file-read-metadata (path-ancestors \(quote(path))))"]
        }
    }

    /// A group name is one path component of ordinary characters: never "..", a slash or a wildcard.
    static func isValidGroup(_ group: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return !group.isEmpty && group.count <= 255 && group != "." && group != ".."
            && group.unicodeScalars.allSatisfy(allowed.contains) && !group.hasPrefix(".")
    }

    /// A path as an anchored SBPL regex: every POSIX metacharacter escaped, and the closing quote too.
    static func regexEscape(_ path: String) -> String {
        var out = ""
        for character in path {
            if "\\.^$|?*+()[]{}\"".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// The path the kernel matches: links in the folders that exist are resolved (/var is /private/var;
    /// a home folder may sit behind a link), and the parts not created yet are appended.
    static func canonical(_ url: URL) -> URL {
        var existing = url.standardizedFileURL, rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        guard let real = realpath(existing.path, nil) else { return url }
        defer { free(real) }
        return rest.reduce(URL(fileURLWithPath: String(cString: real))) { $0.appendingPathComponent($1) }
    }

    static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
}
