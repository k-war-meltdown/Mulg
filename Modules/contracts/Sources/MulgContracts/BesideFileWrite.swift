import Foundation
import Darwin

extension Data {
    /// Replaces `url` in one step without a temporary folder: the bytes go to `<file>.sb-<UUID>` in the same
    /// folder, which is then renamed over `url`. A file and its neighbour are always on one volume, and the
    /// game sandbox allows exactly that name next to each of the game's files (`GameSandboxAccess.fileSuffixes`).
    ///
    /// `.atomic` asks macOS for a replacement folder instead. In a game whose data was moved to another drive,
    /// that folder (the container's tmp or Library/Caches) is a link to that drive, so every save of Mulg's own
    /// files on the Mac's disk failed with a cross-device rename: control profiles from the in-game editor,
    /// settings, safe-mode records, login keys and diagnostics (Endfield, 2026-10-17). Use this for every file
    /// Mulg writes from inside a game.
    public func writeBeside(to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(url.lastPathComponent + ".sb-" + UUID().uuidString)
        do {
            try write(to: temporary, options: .withoutOverwriting)
            guard rename(temporary.path, url.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSFilePathErrorKey: url.path, NSLocalizedDescriptionKey:
                                         "Could not replace \(url.lastPathComponent): \(String(cString: strerror(errno)))"])
            }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }
}

extension String {
    /// `Data.writeBeside(to:)` for text.
    public func writeBeside(to url: URL, encoding: String.Encoding = .utf8) throws {
        guard let data = data(using: encoding) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        try data.writeBeside(to: url)
    }
}
