#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import CryptoKit
import Foundation
import Security

/// The opaque private-key representation is wrapped by this Mac's Secure Enclave.
/// Reading an envelope requires native key agreement under the requested access policy.
nonisolated enum ProtectedPasswordEnvelope {
    private struct Envelope: Codable {
        let version: Int
        let owner: String
        let accessibility: String
        let privateKey: Data
        let peer: Data
        let ciphertext: Data
    }

    private static let context = Data("io.mulg.password-envelope.v1".utf8)
    private static let policies = Set([kSecAttrAccessibleAfterFirstUnlock, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecAttrAccessibleWhenUnlocked, kSecAttrAccessibleWhenUnlockedThisDeviceOnly].map { $0 as String })

    static func transform(_ data: Data, accessibility: String, opening: Bool) throws -> Data {
        guard policies.contains(accessibility) else { throw status(errSecUnimplemented) }
        guard SecureEnclave.isAvailable else { throw status(errSecUnimplemented) }
        guard let owner = Bundle.main.bundleIdentifier, !owner.isEmpty else { throw status(errSecParam) }
        let binding = context + Data((owner + "\0" + accessibility).utf8)
        if opening {
            let envelope = try PropertyListDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1, envelope.owner == owner, envelope.accessibility == accessibility else { throw status(errSecDecode) }
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: envelope.privateKey)
            let peer = try P256.KeyAgreement.PublicKey(x963Representation: envelope.peer)
            let secret = try key.sharedSecretFromKeyAgreement(with: peer)
            let symmetric = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: context, sharedInfo: binding, outputByteCount: 32)
            return try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.ciphertext), using: symmetric, authenticating: binding)
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, accessibility as CFString, .privateKeyUsage, &error) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw status(errSecParam)
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(compactRepresentable: false, accessControl: access)
        let peer = P256.KeyAgreement.PrivateKey()
        let secret = try key.sharedSecretFromKeyAgreement(with: peer.publicKey)
        let symmetric = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: context, sharedInfo: binding, outputByteCount: 32)
        guard let ciphertext = try AES.GCM.seal(data, using: symmetric, authenticating: binding).combined else { throw status(errSecDecode) }
        let envelope = Envelope(version: 1, owner: owner, accessibility: accessibility, privateKey: key.dataRepresentation,
            peer: peer.publicKey.x963Representation, ciphertext: ciphertext)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(envelope)
    }

    private static func status(_ code: OSStatus) -> NSError { NSError(domain: NSOSStatusErrorDomain, code: Int(code)) }
}
#endif
