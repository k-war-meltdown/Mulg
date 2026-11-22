import Foundation

/// Where a game's files live (PLAN.md §13.3): everything it downloads belongs in the folder chosen at
/// installation (`Support/<id>/Data` beside the app). Shared by the app (GameDataStorage) and the runtime
/// (GameDataBootstrap), so both leave the same folders to macOS.
public enum GameDataLayout {
    /// Library folders macOS services write to directly; they stay in the game's local sandbox container.
    public static let nativeLibraryNames: Set<String> = ["Preferences", "Cookies", "HTTPStorages", "WebKit",
                                                         "Saved Application State", "SyncedPreferences"]
    /// Library folders games and frameworks download into; linked to the game folder before the game runs.
    public static let downloadLibraryNames = ["Caches", "Application Support"]

    /// An older restored Library can contain the sandbox's forwarding links. Once
    /// copied to their own destinations, those links point back to themselves and
    /// directory creation fails with ELOOP/EIO before the game can start.
    /// Replace only exact self-links in this game's owned external data tree.
    /// Real directories and links to any other location are never changed.
    @discardableResult
    public static func repairSelfLinkedDirectories(in data: URL) throws -> [URL] {
        let files = FileManager.default
        let root = data.deletingLastPathComponent()
        let id = root.lastPathComponent
        guard data.lastPathComponent == "Data", root.deletingLastPathComponent().lastPathComponent == "Support",
              GameSessionLease.isValidBundleIdentifier(id),
              let bytes = try? Data(contentsOf: root.appendingPathComponent("MulgSupport.json")),
              let owner = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              owner["bundleIdentifier"] as? String == id else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        var repaired: [URL] = []
        // Repair a possible Library self-link before looking at its children.
        for directory in [data, data.appendingPathComponent("Library", isDirectory: true)] {
            guard files.fileExists(atPath: directory.path) else { continue }
            let parent = directory.resolvingSymlinksInPath().standardizedFileURL
            for item in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard let destination = try? files.destinationOfSymbolicLink(atPath: item.path) else { continue }
                let target = URL(fileURLWithPath: destination, relativeTo: directory).standardizedFileURL
                // Resolve ancestors, never the final component (which may loop).
                let physicalTarget = target.deletingLastPathComponent().resolvingSymlinksInPath()
                    .appendingPathComponent(target.lastPathComponent).standardizedFileURL
                guard physicalTarget.path == parent.appendingPathComponent(item.lastPathComponent).path else { continue }
                let saved = directory.appendingPathComponent(".mulg-self-link-" + UUID().uuidString)
                try files.moveItem(at: item, to: saved) // Only the link, not its target.
                do {
                    try files.createDirectory(at: item, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
                } catch {
                    if !files.fileExists(atPath: item.path) { try? files.moveItem(at: saved, to: item) }
                    throw error
                }
                try files.removeItem(at: saved) // The saved link is not followed.
                repaired.append(item)
            }
        }
        return repaired
    }
}
