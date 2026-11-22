import CryptoKit
import Foundation
import MulgControlLayout

/// A derived reference cache, separate from imported/user keymaps. Changing a map invalidates
/// its cached references; cached positions never become authoritative map coordinates.
public struct HUDReferenceStore: Sendable {
    // Deferred writes and explicit resets share an order: an old queued snapshot must
    // not recreate the derived cache after the player resets it.
    private static let publicationQueue = DispatchQueue(label: "io.mulg.hud-references", qos: .utility)
    private struct Record: Codable {
        let schema: Int
        let fingerprint: String
        let references: [ControlHUDAnchor]
        let layouts: [HUDLayoutSample]?
    }
    private let folder: URL
    private let file: URL

    public init(keymapFolder: URL, keymapName: String) {
        folder = keymapFolder.appendingPathComponent(".hud-anchors", isDirectory: true)
        let identity = SHA256.hash(data: Data(keymapName.utf8)).map { String(format: "%02x", $0) }.joined()
        file = folder.appendingPathComponent(identity).appendingPathExtension("plist")
    }

    private func fingerprint(_ map: KeymappingData) -> String? {
        var baseline = map
        baseline.mulgHUDAnchors = nil // Explicit references have independent precedence.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(baseline) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func readRecord(for map: KeymappingData) -> Record? {
        guard let expected = fingerprint(map),
              let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, (0...512 * 1024).contains(size.intValue),
              let data = try? Data(contentsOf: file),
              let record = try? PropertyListDecoder().decode(Record.self, from: data),
              record.schema == 1, record.fingerprint == expected else { return nil }
        return record
    }

    public func readLayouts(for map: KeymappingData) -> [HUDLayoutSample] {
        let cached = readRecord(for: map)?.layouts ?? []
        return ControlLayoutSolver(map: map, cached: cached).samples
    }

    public func read(for map: KeymappingData) -> [ControlHUDAnchor] {
        guard let record = readRecord(for: map) else { return [] }
        var checked = map; checked.mulgHUDAnchors = record.references
        return checked.validHUDAnchors
    }

    /// Returns false on failed publication; in-memory tracking can continue without altering maps.
    @discardableResult
    public func write(_ references: [ControlHUDAnchor], for map: KeymappingData,
                      layouts: [HUDLayoutSample]? = nil) -> Bool {
        guard let fingerprint = fingerprint(map) else { return false }
        var checked = map; checked.mulgHUDAnchors = references
        let validated = ControlLayoutSolver(map: map, cached: layouts ?? readLayouts(for: map)).samples
        let record = Record(schema: 1, fingerprint: fingerprint, references: checked.validHUDAnchors, layouts: validated)
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard (try manager.attributesOfItem(atPath: folder.path))[.type] as? FileAttributeType == .typeDirectory else { return false }
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let data = try encoder.encode(record)
            guard data.count <= 512 * 1024 else { return false }
            try data.writeBeside(to: file)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch { return false }
    }

    @discardableResult
    public func remove() -> Bool {
        Self.publicationQueue.sync {
            guard FileManager.default.fileExists(atPath: file.path) else { return true }
            do { try FileManager.default.removeItem(at: file); return true } catch { return false }
        }
    }

    public func writeInBackground(_ references: [ControlHUDAnchor], for map: KeymappingData,
                                  layouts: [HUDLayoutSample]?, completion: @escaping @Sendable (Bool) -> Void) {
        Self.publicationQueue.async {
            let saved = write(references, for: map, layouts: layouts)
            // Callers may reset the cache from completion; never call them under the
            // publication queue or their synchronous removal could deadlock.
            DispatchQueue.global(qos: .utility).async { completion(saved) }
        }
    }
}
