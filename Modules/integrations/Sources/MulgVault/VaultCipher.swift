#if os(macOS) && !targetEnvironment(macCatalyst)
import CommonCrypto
import CryptoKit
import Foundation
import Security

/// How MulgVault encrypts a locked login database (2026-10-10). The key comes from the vault password
/// through PBKDF2-SHA256 with a random salt and many rounds, and AES-GCM seals the file, so a wrong password
/// or a damaged file is detected instead of "decrypting" to noise. Older files were made by `openssl enc
/// -aes-256-cbc`, one hash of the password and no integrity check; they start without this header and
/// still open through openssl, and the next lock writes them in this format.
public enum VaultCipher {
    public enum Failure: Error, Equatable { case wrongPasswordOrDamaged, keyDerivation }

    static let magic = Data("MULGVLT2".utf8)
    static let saltLength = 16
    /// OWASP's 2023 figure for PBKDF2-HMAC-SHA256. A user-chosen password is the weak part, not the cipher.
    public static let defaultRounds: UInt32 = 600_000

    /// Whether `data` is in this format (otherwise it is an older openssl file).
    public static func isSealed(_ data: Data) -> Bool {
        data.count > magic.count + 4 + saltLength && data.prefix(magic.count) == magic
    }

    public static func seal(_ plain: Data, password: String, rounds: UInt32 = defaultRounds) throws -> Data {
        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.keyDerivation }
        let key = try derive(password: password, salt: salt, rounds: rounds)
        var header = magic
        withUnsafeBytes(of: rounds.bigEndian) { header.append(contentsOf: $0) }
        header.append(salt)
        guard let combined = try AES.GCM.seal(plain, using: key, authenticating: header).combined else {
            throw Failure.keyDerivation
        }
        return header + combined
    }

    public static func open(_ sealed: Data, password: String) throws -> Data {
        guard isSealed(sealed) else { throw Failure.wrongPasswordOrDamaged }
        let bytes = [UInt8](sealed)
        let roundsStart = magic.count, saltStart = roundsStart + 4, bodyStart = saltStart + saltLength
        let rounds = bytes[roundsStart..<saltStart].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        // A damaged header must not make Mulg spend minutes deriving a key.
        guard rounds >= 10_000, rounds <= 10_000_000 else { throw Failure.wrongPasswordOrDamaged }
        let header = Data(bytes[..<bodyStart]), salt = Data(bytes[saltStart..<bodyStart])
        let key = try derive(password: password, salt: salt, rounds: rounds)
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(bytes[bodyStart...])), using: key, authenticating: header) }
        catch { throw Failure.wrongPasswordOrDamaged }
    }

    static func derive(password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        let secret = Array(password.utf8)
        var key = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, secret.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &key, key.count)
        }
        guard status == kCCSuccess else { throw Failure.keyDerivation }
        defer { key.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return SymmetricKey(data: key)
    }
}
#endif
