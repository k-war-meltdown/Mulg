import CryptoKit
import Foundation
import Security

/// A small secret (a 32-byte database key, a vault password) sealed by this Mac's Secure Enclave and kept
/// in an ordinary file, so nothing of Mulg's lives in the macOS Keychain (2026-10-10). The Enclave key that
/// opens it exists only as its encrypted blob inside the file, usable on this Mac alone; no process asks
/// the Keychain for anything. `purpose` binds the file to its use: a game's key never opens as another's.
public enum SealedSecret {
    public enum Failure: Error, Equatable {
        case secureEnclaveUnavailable, wrongPurpose, damaged
    }

    private struct Sealed: Codable {
        let version: Int
        let purpose: String
        let enclaveKey: Data
        let peer: Data
        let ciphertext: Data
    }

    private static let salt = Data("io.mulg.sealed-secret.v1".utf8)

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public static func seal(_ secret: Data, purpose: String) throws -> Data {
        guard SecureEnclave.isAvailable else { throw Failure.secureEnclaveUnavailable }
        var error: Unmanaged<CFError>?
        // Usable after the first unlock, on this Mac only; no prompt (Mulg and games open it unattended).
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                           .privateKeyUsage, &error) else {
            throw error.map { $0.takeRetainedValue() as Error } ?? Failure.secureEnclaveUnavailable
        }
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(compactRepresentable: false, accessControl: access)
        let peer = P256.KeyAgreement.PrivateKey()
        let key = symmetricKey(enclave: enclave, peer: peer.publicKey, purpose: purpose)
        guard let ciphertext = try AES.GCM.seal(secret, using: key, authenticating: binding(purpose)).combined else {
            throw Failure.damaged
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(Sealed(version: 1, purpose: purpose, enclaveKey: enclave.dataRepresentation,
                                         peer: peer.publicKey.x963Representation, ciphertext: ciphertext))
    }

    public static func open(_ sealed: Data, purpose: String) throws -> Data {
        guard let value = try? PropertyListDecoder().decode(Sealed.self, from: sealed), value.version == 1 else {
            throw Failure.damaged
        }
        guard value.purpose == purpose else { throw Failure.wrongPurpose }
        guard SecureEnclave.isAvailable else { throw Failure.secureEnclaveUnavailable }
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: value.enclaveKey)
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: value.peer)
        let key = symmetricKey(enclave: enclave, peer: peer, purpose: purpose)
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: value.ciphertext), using: key, authenticating: binding(purpose)) }
        catch { throw Failure.damaged }
    }

    /// Reads a sealed file; nil when it does not exist.
    public static func read(_ file: URL, purpose: String) throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try open(Data(contentsOf: file), purpose: purpose)
    }

    /// Seals into `file` (owner-only, atomic) and reads it back before returning: a secret is never
    /// reported stored unless it opens again.
    public static func write(_ secret: Data, to file: URL, purpose: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try seal(secret, purpose: purpose).writeBeside(to: file)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        guard try read(file, purpose: purpose) == secret else { throw Failure.damaged }
    }

    private static func binding(_ purpose: String) -> Data { salt + Data(purpose.utf8) }

    private static func symmetricKey(enclave: SecureEnclave.P256.KeyAgreement.PrivateKey, peer: P256.KeyAgreement.PublicKey,
                                     purpose: String) -> SymmetricKey {
        // Agreement cannot fail for a valid pair; a failure leaves a key that opens nothing.
        let secret = try? enclave.sharedSecretFromKeyAgreement(with: peer)
        return secret?.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: binding(purpose), outputByteCount: 32)
            ?? SymmetricKey(size: .bits256)
    }
}

extension ContainerPaths {
    /// A game's credential database key, sealed (SealedSecret): next to its database, inside its own sandbox grant.
    public func mulgChainKey(for bundleIdentifier: String) -> URL {
        mulgChainDirectory.appendingPathComponent("\(bundleIdentifier).key", isDirectory: false)
    }

    /// The purpose a game's database key is sealed for.
    public static func mulgChainKeyPurpose(for bundleIdentifier: String) -> String { "credentials/" + bundleIdentifier }
}
