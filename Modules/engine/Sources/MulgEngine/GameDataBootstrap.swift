import Foundation
import Darwin
import MulgContracts
import MulgEngineHooks

/// Publish actual external URLs after macOS initializes the sandbox. Keeping its structural
/// Library directory intact avoids Container Manager repair and cross-volume atomic writes.
@objc(MulgGameDataBootstrap)
public final class GameDataBootstrap: NSObject {
    public enum Failure: Error { case unavailable(String), invalidRoot(String), hooksUnavailable }
    private struct Owner: Decodable { let bundleIdentifier: String }
    @objc(prepareWithBundle:error:)
    public static func prepare(bundle: Bundle) throws {
        guard let path = bundle.object(forInfoDictionaryKey: "MulgGameDataRoot") as? String else { return }
        // A game opened from Finder or the Dock right after the app updated it can find its folder
        // briefly unreadable. Every step below is repeatable, and the launch fails without it, so a
        // few short retries cost nothing but a delay before a real failure is reported.
        var attempt = 0
        while true {
            do { return try prepare(bundle: bundle, path: path) } catch Failure.unavailable where attempt < retries {
                attempt += 1
                usleep(retryDelay)
            }
        }
    }

    static let retries = 6
    static let retryDelay: useconds_t = 500_000

    /// The POSIX reason under a Foundation file error, else its description.
    static func reason(_ error: any Error) -> String {
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        if let posix = underlying, posix.domain == NSPOSIXErrorDomain { return String(cString: strerror(Int32(posix.code))) }
        return (error as NSError).localizedDescription
    }

    private static func prepare(bundle: Bundle, path: String) throws {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard let id = bundle.bundleIdentifier, root.lastPathComponent == id,
              root.deletingLastPathComponent().lastPathComponent == "Support" else {
            // Not a Mulg game-data root: no retry helps.
            throw Failure.invalidRoot(path)
        }
        // Each failure names its step and the system's reason, so a report says why.
        let bytes: Data
        do { bytes = try Data(contentsOf: root.appendingPathComponent("MulgSupport.json")) } catch {
            throw Failure.unavailable("\(path) (owner record unreadable: \(reason(error)))")
        }
        guard (try? JSONDecoder().decode(Owner.self, from: bytes))?.bundleIdentifier == id else {
            throw Failure.unavailable("\(path) (owner record names another game)")
        }
        let data = root.appendingPathComponent("Data", isDirectory: true)
        let files = FileManager.default
        // Also cover direct/Finder launches and data restored after host preparation.
        // This runs before publishing storage hooks or starting the game's engine.
        do {
            try GameDataLayout.repairSelfLinkedDirectories(in: data)
            for name in ["Documents", "Library", "Library/Caches", "Library/Application Support", "Library/Preferences", "SystemData", "tmp"] {
                try files.createDirectory(at: data.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            let probe = data.appendingPathComponent(".runtime-access-" + UUID().uuidString)
            try Data("game data".utf8).write(to: probe, options: .atomic)
            try files.removeItem(at: probe)
        } catch {
            throw Failure.unavailable("\(data.path) (not writable: \(reason(error)))")
        }
        // Still before the game's code: the hooks below send the game's own requests to the game folder,
        // but frameworks compute container paths themselves. Empty local Library folders, and the download
        // folders not made yet, become links now, so in-game downloads land in the game folder from the
        // first launch. Non-empty ones are moved by the app before the next launch (sweepLocalLibrary).
        let nativeHome = URL(fileURLWithPath: NSHomeDirectory())
        linkStandardFolders(local: nativeHome, external: data)
        linkLibraryFolders(local: nativeHome.appendingPathComponent("Library"),
                           external: data.appendingPathComponent("Library"))
        // Publish owned roots before installing Foundation path builders, so
        // download SDK initialization sees the same paths as later C file I/O.
        // EngineCore later adds its real-home root and legacy Unreal policy.
        mulg_engine_configure_game_path_roots([nativeHome.path, data.path, bundle.bundleURL.path], false)
        guard data.path.withCString({ mulg_engine_set_game_data_root($0) }) else { throw Failure.hooksUnavailable }
        // Keep the process HOME native: cfprefsd and system services own the sandbox's
        // structural preferences path. Only direct game directory requests are redirected.
        // Process-wide TMPDIR is also used by Foundation/Metal for local runtime state.
        // Direct game temporary-directory API requests are redirected by the hooks.
        try JSONSerialization.data(withJSONObject: ["bundleIdentifier": id])
            .write(to: root.appendingPathComponent("MulgRuntimeDataReady.json"), options: .atomic)
    }

    /// Links `local`'s empty folders and missing download folders to `external`; never touches a folder
    /// holding files, a link, or one macOS owns (`GameDataLayout.nativeLibraryNames`). Best effort: a
    /// folder that cannot be linked stays local and is moved by the app before the next launch.
    @discardableResult
    static func linkLibraryFolders(local: URL, external: URL) -> [String] {
        let files = FileManager.default
        guard (try? local.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [] }
        var names = Set(GameDataLayout.downloadLibraryNames)
        names.formUnion((try? files.contentsOfDirectory(atPath: local.path)) ?? [])
        return linkEmptyFolders(local: local, external: external, names: names.subtracting(GameDataLayout.nativeLibraryNames))
    }

    // Native frameworks and SDKs shared with another process keep native directory APIs.
    // Their standard game folders must reach the same files, including on a first launch.
    @discardableResult
    static func linkStandardFolders(local: URL, external: URL) -> [String] {
        linkEmptyFolders(local: local, external: external, names: ["Documents", "SystemData", "tmp"])
    }

    private static func linkEmptyFolders(local: URL, external: URL, names: Set<String>) -> [String] {
        let files = FileManager.default
        var linked: [String] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let item = local.appendingPathComponent(name), target = external.appendingPathComponent(name)
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values != nil {
                // Only an empty real folder is replaced; anything with files is the app's to move.
                guard values?.isDirectory == true, (try? files.contentsOfDirectory(atPath: item.path))?.isEmpty == true else { continue }
            }
            do {
                try files.createDirectory(at: target, withIntermediateDirectories: true)
                if values != nil, item.path.withCString({ rmdir($0) }) != 0 { continue }
                try files.createSymbolicLink(at: item, withDestinationURL: target)
                linked.append(name)
            } catch {
                _ = item.path.withCString { mkdir($0, 0o700) } // Refuses existing files and links.
            }
        }
        return linked
    }
}
