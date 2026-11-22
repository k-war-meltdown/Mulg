#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MulgContracts
import MulgLibrary

/// The native Keychain keeps the pending password; this journal contains only ciphertext
/// and identifiers. Once prepared, recovery finishes the same rotation before games launch.
public enum VaultPasswordRotation {
    private static func staging(_ folder: URL) -> URL { folder.appendingPathComponent(".password-rotation") }
    private static func journal(_ folder: URL) -> URL { staging(folder).appendingPathComponent("record.json") }
    public static func hasPending(in folder: URL) -> Bool { FileManager.default.fileExists(atPath: journal(folder).path) }

    public static func prepare(in folder: URL, identifiers: [String],
                               transform: (String, URL) throws -> Void) throws {
        guard Set(identifiers).count == identifiers.count,
              identifiers.allSatisfy(GameSessionLease.isValidBundleIdentifier), !hasPending(in: folder) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let files = FileManager.default
        let stage = staging(folder)
        if files.fileExists(atPath: stage.path) { try files.removeItem(at: stage) }
        try files.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            for id in identifiers {
                let target = stage.appendingPathComponent(id + "." + ContainerPaths.legacyVaultExtension)
                try transform(id, target)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                try BundleTransaction.flush(target, full: true)
            }
            try BundleTransaction.flush(stage)
            try JSONEncoder().encode(identifiers).write(to: journal(folder), options: .atomic)
            try BundleTransaction.flush(journal(folder), full: true)
            try BundleTransaction.flush(stage)
            try BundleTransaction.flush(folder)
        } catch {
            if !hasPending(in: folder) { try? files.removeItem(at: stage) }
            throw error
        }
    }

    public static func recover(in folder: URL, commitPassword: () throws -> Void) throws {
        let files = FileManager.default
        guard hasPending(in: folder) else { return }
        let identifiers = try JSONDecoder().decode([String].self, from: Data(contentsOf: journal(folder)))
        guard Set(identifiers).count == identifiers.count,
              identifiers.allSatisfy(GameSessionLease.isValidBundleIdentifier) else { throw CocoaError(.fileReadCorruptFile) }
        for id in identifiers {
            let name = id + "." + ContainerPaths.legacyVaultExtension
            let source = staging(folder).appendingPathComponent(name)
            let kind = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard kind.isRegularFile == true, kind.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
            let target = folder.appendingPathComponent(name)
            try Data(contentsOf: source).write(to: target, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try BundleTransaction.flush(target, full: true)
        }
        try BundleTransaction.flush(folder)
        // The old password stays available until all replacements are durably installed.
        try commitPassword()
        for id in identifiers {
            let plain = folder.appendingPathComponent(id + ".db")
            if files.fileExists(atPath: plain.path) { try files.removeItem(at: plain) }
        }
        try BundleTransaction.flush(folder)
        // Remove the journal before its ciphertext, so interrupted cleanup stays idempotent.
        try files.removeItem(at: journal(folder))
        try BundleTransaction.flush(staging(folder))
        try files.removeItem(at: staging(folder))
        try BundleTransaction.flush(folder)
    }
}
#endif
