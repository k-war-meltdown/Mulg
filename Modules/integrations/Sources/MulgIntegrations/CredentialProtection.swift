import CryptoKit
import Foundation

/// Secrets stay compatible with the existing database layout; the encryption key stays in the system Keychain.
enum CredentialProtection {
    static let prefix = Data("MulgSecret1\0".utf8)

    static func seal(_ value: SQLValue, key: SymmetricKey) throws(MulgChainError) -> SQLValue {
        let payload: Data
        switch value {
        case .null: return .null
        case .blob(let data): payload = Data([0]) + data
        case .text(let text): payload = Data([1]) + Data(text.utf8)
        }
        do {
            guard let combined = try AES.GCM.seal(payload, using: key).combined else { throw MulgChainError.unavailable("credential encryption failed") }
            return .blob(prefix + combined)
        } catch { throw .unavailable("credential encryption failed") }
    }

    static func open(_ value: SQLValue, key: SymmetricKey, allowPlaintext: Bool = false) throws(MulgChainError) -> SQLValue {
        if value == .null { return .null }
        guard case .blob(let data) = value, data.starts(with: prefix) else {
            if allowPlaintext { return value }
            throw .unavailable("unprotected credential in protected database")
        }
        do {
            let payload = try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(prefix.count)), using: key)
            guard let type = payload.first else { throw MulgChainError.unavailable("invalid protected credential") }
            if type == 0 { return .blob(Data(payload.dropFirst())) }
            if type == 1, let text = String(data: payload.dropFirst(), encoding: .utf8) { return .text(text) }
            throw MulgChainError.unavailable("invalid protected credential")
        } catch { throw .unavailable("credential authentication failed") }
    }
}
