#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MulgContracts

/// Read-only discovery in game/source locations on every mounted writable drive.
/// Inspect one grouping folder below each root, without walking entire drives.
/// Bundle IDs and Mulg ownership records establish removal targets. A filename
/// resemblance never authorizes deleting or trashing personal files.
public enum GameRemovalScan {
    public enum Kind: String, Codable, Sendable {
        /// The game or a converted copy (Info.plist ID, plus Mulg's entitlement record for copies).
        case bundle
        /// A Support folder with Mulg's owner file.
        case support
        /// Legacy pending-record kind; shared App Groups are retained without exclusive ownership proof.
        case group
        /// Kept for decoding older pending records; name-only deletion is no longer allowed.
        case leftover
        /// Source IPA with exactly one top-level app and the same plist bundle ID.
        case archive
        /// Mulg save version with matching settings metadata and parent bundle ID.
        case backup
    }
    public struct Item: Codable, Sendable, Equatable {
        public let url: URL
        public let kind: Kind
        public init(url: URL, kind: Kind) { self.url = url; self.kind = kind }
    }
    public struct Inventory: Sendable {
        public let bundleIdentifier: String
        public let app: URL
        public let items: [Item]
        /// Every folder that was looked at.
        public let checkedFolders: [URL]
        /// Recorded data folders on drives that are not connected; kept for a later retry.
        public let unavailableRoots: [URL]
        /// Native Mac apps sharing the ID, whose app and shared Library data are retained.
        public let nativeApps: [URL]
        /// App groups retained because exclusive ownership cannot be established.
        public let sharedGroups: [String]
        public let issues: [String]
        public let deniedFolders: [URL]
    }

    static let originalEntitlements = "MulgOriginalEntitlements.plist"

    /// `installFolders`: folders the player chose for installs (the host's install setting).
    /// `volumes` replaces the mounted drives (tests).
    public static func discover(app: URL, bundleIdentifier id: String, paths: ContainerPaths = .current(),
                                installFolders: [URL] = [], volumes: [URL]? = nil) throws -> Inventory {
        guard GameSessionLease.isValidBundleIdentifier(id) else { throw GameSessionLease.Failure.invalidIdentifier }
        let files = FileManager.default
        let installed = canonical(app.resolvingSymlinksInPath())
        var found: [String: Item] = [:], native: Set<String> = [], issues: [String] = []
        var unavailable: Set<URL> = [], checked: [URL] = [], seenFolders: [String: Int] = [:]
        var deniedFolders: Set<URL> = []
        func note(_ text: String) { if issues.count < 100, !issues.contains(text) { issues.append(text) } }
        @discardableResult func remember(_ url: URL, _ kind: Kind) -> Bool {
            let item = Item(url: canonical(url), kind: kind)
            guard found[item.url.path] == nil else { return true }
            if validates(item, identifier: id, selectedApp: installed) { found[item.url.path] = item; return true }
            if kind == .bundle, bundleIdentifier(at: item.url) == id {
                native.insert(item.url.path)
            }
            return false
        }
        func supportBeside(_ folder: URL) {
            let root = folder.appendingPathComponent("Support/" + id, isDirectory: true)
            guard BundleTransaction.exists(root) else { return }
            if !remember(root, .support) { note("Ownership could not be verified, kept: \(root.path)") }
        }
        /// Inspect install roots and one grouping folder (Applications/TFT, etc.).
        /// This does not recursively walk a drive or downloaded asset trees.
        func checkInstallFolder(_ folder: URL, depth: Int = 1) {
            guard !Task.isCancelled else { return }
            // ~/Applications can itself link to an external Applications folder.
            let folder = canonical(folder.resolvingSymlinksInPath())
            guard (seenFolders[folder.path] ?? -1) < depth, !isOnDisconnectedVolume(folder),
                  BundleTransaction.exists(folder) else { return }
            if seenFolders[folder.path] == nil { checked.append(folder) }
            seenFolders[folder.path] = depth
            supportBeside(folder)
            let entries: [URL]
            do { entries = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey],
                                                         options: [.skipsHiddenFiles]) }
            catch {
                note("Could not check \(folder.path): \(error.localizedDescription)")
                if GameCleanup.isPermissionError(error) { deniedFolders.insert(folder) }
                return
            }
            for entry in entries {
                guard !Task.isCancelled else { return }
                let target = entry.resolvingSymlinksInPath()
                guard !isOnDisconnectedVolume(target), BundleTransaction.exists(target) else { continue }
                if target.pathExtension.lowercased() == "app" {
                    if remember(target, .bundle) { supportBeside(target.deletingLastPathComponent()) }
                } else if target.pathExtension.lowercased() == "ipa" {
                    remember(target, .archive)
                } else if target.deletingLastPathComponent().lastPathComponent == id, backupIdentifier(target) == id {
                    remember(target, .backup)
                } else if depth > 0, target.lastPathComponent != "Support",
                          let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                          values.isDirectory == true, values.isPackage != true {
                    checkInstallFolder(target, depth: depth - 1)
                }
            }
        }

        // 1. Exact recorded locations, so a disconnected drive is still remembered.
        let record = GameDataStorage.locationsFile(id, paths: paths)
        var recorded: [URL] = []
        if BundleTransaction.exists(record) {
            do { recorded = try JSONDecoder().decode([URL].self, from: Data(contentsOf: record)) }
            catch { note("The saved data-location record could not be read: \(record.path)") }
        }
        recorded.append(try GameDataStorage.root(for: installed, bundleIdentifier: id))
        if let pending = try? GameCleanup.pendingRemovals(paths: paths).first(where: { $0.bundleIdentifier == id }) {
            recorded += pending.remaining.filter { $0.kind == .support }.map(\.url)
            for item in pending.remaining where item.kind != .support && !isOnDisconnectedVolume(item.url)
                && BundleTransaction.exists(item.url) {
                remember(item.url, item.kind)
            }
        }
        for root in Set(recorded.map { $0.standardizedFileURL }) {
            guard root.lastPathComponent == id, root.deletingLastPathComponent().lastPathComponent == "Support" else {
                note("An unrecognized saved data location was kept: \(root.path)"); continue
            }
            if isOnDisconnectedVolume(root) { unavailable.insert(root); continue }
            if BundleTransaction.exists(root), !remember(root, .support) { note("Ownership could not be verified, kept: \(root.path)") }
            // A recorded Support folder sits beside the folder the game was installed in.
            checkInstallFolder(root.deletingLastPathComponent().deletingLastPathComponent())
        }
        if BundleTransaction.exists(installed) { remember(installed, .bundle) }

        // 2. Install folders: the game's own, the Mulg library, chosen folders, and on every
        // mounted writable drive its top level and its Applications folder.
        var folders = [installed.deletingLastPathComponent(), paths.applicationsDirectory,
                       paths.home.appendingPathComponent("Applications"), paths.home.appendingPathComponent("Applications/Mulg")]
            + installFolders
        for volume in volumes ?? mountedWritableVolumes(note: note) {
            folders += [volume, volume.appendingPathComponent("Applications")]
        }
        for folder in folders { checkInstallFolder(folder) }

        // 3. Entitlements prove group access, not exclusive ownership of the folder.
        // Offline/native apps can share a publisher group without appearing in Mulg.
        // Keep these instead of risking another app's account data or saves.
        var groups: Set<String> = [], shared: Set<String> = []
        for bundle in found.values where bundle.kind == .bundle { groups.formUnion(appGroups(of: bundle.url)) }
        if !groups.isEmpty {
            let library = (try? files.contentsOfDirectory(at: paths.applicationsDirectory, includingPropertiesForKeys: nil)) ?? []
            for other in library where other.pathExtension == "app" {
                let target = other.resolvingSymlinksInPath()
                guard let otherID = GameInstaller.infoPlist(target)?["CFBundleIdentifier"] as? String, otherID != id else { continue }
                shared.formUnion(groups.intersection(appGroups(of: target)))
            }
            shared.formUnion(groups)
        }

        // 4. Verify IPA metadata in common source/backup locations. A personal file
        // named after the game is kept unless its own metadata establishes ownership.
        for name in ["Documents", "Desktop", "Downloads"] {
            let folder = paths.home.appendingPathComponent(name, isDirectory: true)
            checkInstallFolder(folder)
        }
        try Task.checkCancellation()
        return Inventory(bundleIdentifier: id, app: installed, items: found.values.sorted { $0.url.path < $1.url.path },
                         checkedFolders: checked, unavailableRoots: unavailable.sorted { $0.path < $1.path },
                         nativeApps: native.sorted().map { URL(fileURLWithPath: $0) }, sharedGroups: shared.sorted(),
                         issues: issues, deniedFolders: deniedFolders.sorted { $0.path < $1.path })
    }

    /// The root volume and every mounted drive that can be written to. Read-only and hidden mounts
    /// (system snapshots, disk images, simulator runtimes) cannot hold a removable install.
    static func mountedWritableVolumes(note: (String) -> Void) -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsReadOnlyKey, .volumeIsBrowsableKey]
        var volumes = [URL(fileURLWithPath: "/", isDirectory: true)]
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? [] {
            let path = volume.resolvingSymlinksInPath().standardizedFileURL.path
            guard path != "/", !path.hasPrefix("/System/Volumes/"), !path.hasPrefix("/Library/Developer/") else { continue }
            let values = try? volume.resourceValues(forKeys: Set(keys))
            if values?.volumeIsBrowsable == false || values?.volumeIsReadOnly == true { continue }
            volumes.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        return volumes
    }

    static func leftoverName(_ name: String, id: String) -> Bool {
        name == id || (name.hasPrefix(id + ".") && !name.dropFirst(id.count + 1).contains("."))
    }

    static func appGroups(of bundle: URL) -> [String] {
        guard let bytes = try? Data(contentsOf: bundle.appendingPathComponent(originalEntitlements)),
              let tree = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else { return [] }
        return (tree["com.apple.security.application-groups"] as? [String] ?? []).filter(GameSandboxAccess.isValidGroup)
    }

    static func canonical(_ url: URL) -> URL { URL(fileURLWithPath: url.standardizedFileURL.path) }

    public static func isOnDisconnectedVolume(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/" + parts[2])
    }

    static func validates(_ item: Item, identifier id: String, selectedApp: URL) -> Bool {
        guard (try? item.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
        switch item.kind {
        case .support:
            guard item.url.lastPathComponent == id, item.url.deletingLastPathComponent().lastPathComponent == "Support",
                  let bytes = try? Data(contentsOf: item.url.appendingPathComponent("MulgSupport.json")) else { return false }
            return (try? JSONDecoder().decode(GameDataStorage.Owner.self, from: bytes))?.bundleIdentifier == id
        case .bundle:
            guard GameInstaller.infoPlist(item.url)?["CFBundleIdentifier"] as? String == id else { return false }
            // An independently installed native Mac app may share the ID. Only the
            // selected game or a converted Mulg copy belongs to this operation.
            return item.url.standardizedFileURL.path == selectedApp.standardizedFileURL.path
                || BundleTransaction.exists(item.url.appendingPathComponent(originalEntitlements))
        case .group:
            return false // Access entitlements do not establish exclusive data ownership.
        case .leftover:
            return false
        case .archive: return archiveIdentifier(item.url) == id
        case .backup: return backupIdentifier(item.url) == id
        }
    }

    private static func bundleIdentifier(at app: URL) -> String? {
        if let id = GameInstaller.infoPlist(app)?["CFBundleIdentifier"] as? String { return id }
        guard let bytes = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let tree = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else { return nil }
        return tree["CFBundleIdentifier"] as? String
    }

    private static func backupIdentifier(_ folder: URL) -> String? {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("Data.zip").path)
            || FileManager.default.fileExists(atPath: folder.appendingPathComponent("Keymapping.zip").path),
              let bytes = try? Data(contentsOf: folder.appendingPathComponent("Settings.plist")),
              let tree = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let id = tree["bundleIdentifier"] as? String,
              folder.deletingLastPathComponent().lastPathComponent == id else { return nil }
        return id
    }

    private static func archiveIdentifier(_ file: URL) -> String? {
        guard let listing = archiveOutput(["-Z1", file.path], limit: 16 << 20),
              let names = String(data: listing, encoding: .utf8) else { return nil }
        let plists = names.split(separator: "\n").filter { name in
            let parts = name.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }
        guard plists.count == 1,
              let bytes = archiveOutput(["-p", file.path, String(plists[0])], limit: 2 << 20),
              let tree = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else { return nil }
        return tree["CFBundleIdentifier"] as? String
    }

    /// Read only the ZIP directory and one bounded plist; never unpack assets.
    private static func archiveOutput(_ arguments: [String], limit: Int) -> Data? {
        guard !Task.isCancelled else { return nil }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 10)
        timer.setEventHandler { if process.isRunning { process.terminate() } }
        timer.resume()
        defer { timer.cancel(); try? pipe.fileHandleForReading.close() }
        var data = Data()
        while !Task.isCancelled {
            guard let bytes = try? pipe.fileHandleForReading.read(upToCount: min(65_536, limit + 1 - data.count)),
                  !bytes.isEmpty else { break }
            data.append(bytes)
            if data.count > limit { break }
        }
        if data.count > limit || Task.isCancelled { if process.isRunning { process.terminate() } }
        process.waitUntilExit()
        return process.terminationStatus == 0 && data.count <= limit && !Task.isCancelled ? data : nil
    }
}
#endif
