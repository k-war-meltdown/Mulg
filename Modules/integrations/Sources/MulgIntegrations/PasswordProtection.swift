import Foundation
import Security

/// Native protected envelopes remain inside the per-game encrypted database. No plaintext
/// fallback is allowed when the bridge is absent, locked or cannot satisfy the policy.
public struct PasswordProtection: @unchecked Sendable {
    public typealias Operation = (Data, String, Bool) -> (OSStatus, Data?)
    private let operation: Operation
    private static let prefix = Data("MulgPassword1\0".utf8)
    static let policies = Set([kSecAttrAccessibleAfterFirstUnlock, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecAttrAccessibleWhenUnlocked, kSecAttrAccessibleWhenUnlockedThisDeviceOnly].map { $0 as String })

    /// The native policy a requested accessibility is sealed under: the four native ones as they are, and the
    /// rest as the nearest one at least as strong. `Always` ("dk", "dku"; deprecated, still common in older
    /// sign-in SDKs) becomes "after first unlock"; "when passcode set" becomes "when unlocked" (a Mac always has
    /// a login password). These were refused, which made such a game's token save, and so its login, fail.
    /// The game still reads back the accessibility it asked for. Nil: no native policy fits.
    static func nativePolicy(for requested: String) -> String? {
        if policies.contains(requested) { return requested }
        if requested == "dk" { return kSecAttrAccessibleAfterFirstUnlock as String }
        if requested == "dku" { return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String }
        if requested == kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String {
            return kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        }
        return nil
    }

    public init(operation: @escaping Operation) { self.operation = operation }

    func seal(_ value: SQLValue, accessibility requested: String) throws(MulgChainError) -> SQLValue {
        guard let accessibility = Self.nativePolicy(for: requested) else { throw .native(errSecUnimplemented) }
        if value == .null { return .null }
        guard case .blob(let bytes) = value else { throw .invalidQuery }
        let (status, protected) = operation(bytes, accessibility, false)
        guard status == errSecSuccess, let protected else { throw .native(status == errSecSuccess ? errSecDecode : status) }
        return .blob(Self.prefix + protected)
    }

    static func isEnvelope(_ value: SQLValue) -> Bool {
        if case .blob(let bytes) = value { return bytes.starts(with: prefix) }
        return false
    }

    func open(_ value: SQLValue, accessibility requested: String) throws(MulgChainError) -> SQLValue {
        guard case .blob(let bytes) = value, Self.isEnvelope(value), let accessibility = Self.nativePolicy(for: requested)
        else { throw .native(errSecDecode) }
        let (status, plaintext) = operation(Data(bytes.dropFirst(Self.prefix.count)), accessibility, true)
        guard status == errSecSuccess, let plaintext else { throw .native(status == errSecSuccess ? errSecDecode : status) }
        return .blob(plaintext)
    }
}
