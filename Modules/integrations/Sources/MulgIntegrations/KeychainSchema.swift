import Foundation
import Security

/// The MulgChain database layout, identical to upstream's `MulgKeychainDBConstants`, so a
/// game's existing keychain file keeps working: one table per item class, named after the
/// class ("genp", "inet", "cert", "keys", "idnt"), with one TEXT column per attribute key.
public enum KeychainSchema {
    public struct Table: Sendable, Equatable {
        public let name: String
        /// The attributes that make an item unique (Apple's documented primary keys).
        public let primaries: [String]
        /// The other attributes kept for the item.
        public let attributes: [String]

        /// Every column, in upstream's order.
        public var columns: [String] {
            primaries + attributes + KeychainSchema.values
        }
    }

    public static let values: [String] = [kSecValueData, kSecValueRef, kSecValuePersistentRef].map(string)

    public static let tables: [String: Table] = {
        let passwordAttributes = [
            kSecAttrAccessControl, kSecAttrAccessible, kSecAttrCreationDate, kSecAttrModificationDate,
            kSecAttrDescription, kSecAttrComment, kSecAttrCreator, kSecAttrType, kSecAttrLabel,
            kSecAttrIsInvisible, kSecAttrIsNegative, kSecAttrGeneric
        ].map(string)
        let certificateAttributes = [
            kSecAttrCertificateEncoding, kSecAttrLabel, kSecAttrSubject, kSecAttrSubjectKeyID, kSecAttrPublicKeyHash
        ].map(string)
        let list = [
            Table(name: string(kSecClassGenericPassword),
                  primaries: [kSecAttrAccessGroup, kSecAttrAccount, kSecAttrService].map(string),
                  attributes: passwordAttributes),
            Table(name: string(kSecClassInternetPassword),
                  primaries: [kSecAttrAccessGroup, kSecAttrAccount, kSecAttrAuthenticationType, kSecAttrPath,
                              kSecAttrPort, kSecAttrProtocol, kSecAttrSecurityDomain, kSecAttrServer].map(string),
                  attributes: passwordAttributes),
            Table(name: string(kSecClassCertificate),
                  primaries: [kSecAttrAccessGroup, kSecAttrCertificateType, kSecAttrIssuer, kSecAttrSerialNumber].map(string),
                  attributes: certificateAttributes),
            Table(name: string(kSecClassKey),
                  primaries: [kSecAttrAccessGroup, kSecAttrApplicationLabel, kSecAttrApplicationTag,
                              kSecAttrEffectiveKeySize, kSecAttrKeyClass, kSecAttrKeySizeInBits, kSecAttrKeyType].map(string),
                  attributes: [kSecAttrAccessible, kSecAttrLabel, kSecAttrIsPermanent, kSecAttrCanEncrypt,
                               kSecAttrCanDecrypt, kSecAttrCanDerive, kSecAttrCanSign, kSecAttrCanVerify,
                               kSecAttrCanWrap, kSecAttrCanUnwrap].map(string)),
            Table(name: string(kSecClassIdentity),
                  primaries: [kSecAttrAccessGroup, kSecAttrCertificateType, kSecAttrIssuer, kSecAttrSerialNumber].map(string),
                  attributes: certificateAttributes)
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
    }()

    /// Every stored attribute can constrain a query; retain the public schema lookup.
    public static let matchableAttributes: Set<String> = Set(tables.values.flatMap(\.attributes))

    /// Never compared when matching. The database belongs to one game, so the access group
    /// can't separate anything; games often add without it and search with it (or the
    /// reverse), which upstream answered with "not found".
    public static let unmatchedPrimaries: Set<String> = [string(kSecAttrAccessGroup)]

    // MARK: Value kinds, so values read back have the type the game stored

    /// Stored as text because the columns are TEXT, read back as numbers.
    public static let integerAttributes: Set<String> = Set([
        kSecAttrPort, kSecAttrKeySizeInBits, kSecAttrEffectiveKeySize, kSecAttrCertificateType,
        kSecAttrCertificateEncoding, kSecAttrCreator, kSecAttrType
    ].map(string))

    public static let booleanAttributes: Set<String> = Set([
        kSecAttrIsInvisible, kSecAttrIsNegative, kSecAttrIsPermanent, kSecAttrCanEncrypt, kSecAttrCanDecrypt,
        kSecAttrCanDerive, kSecAttrCanSign, kSecAttrCanVerify, kSecAttrCanWrap, kSecAttrCanUnwrap
    ].map(string))

    public static let dateAttributes: Set<String> = Set([kSecAttrCreationDate, kSecAttrModificationDate].map(string))

    public static func table(for itemClass: Any?) -> Table? {
        guard let name = itemClass as? String else { return nil }
        return tables[name]
    }

    /// `kSecAttrKeyType` and `kSecAttrType` are both "type"; that is how upstream's
    /// "type"/"kcls" comments arose. The helper keeps call sites readable.
    public static func string(_ key: CFString) -> String {
        key as String
    }
}

/// The keys of a keychain query that are not attributes (Apple's "search" and "return" keys).
enum KeychainKey {
    static let itemClass = kSecClass as String
    static let matchLimit = kSecMatchLimit as String
    static let matchItemList = kSecMatchItemList as String
    static let returnData = kSecReturnData as String
    static let returnAttributes = kSecReturnAttributes as String
    static let returnRef = kSecReturnRef as String
    static let returnPersistentRef = kSecReturnPersistentRef as String
    static let valueData = kSecValueData as String
    static let valueRef = kSecValueRef as String
    static let valuePersistentRef = kSecValuePersistentRef as String
    static let synchronizable = kSecAttrSynchronizable as String
    static let keyType = kSecAttrKeyType as String
    static let keyClass = kSecAttrKeyClass as String
    static let isPermanent = kSecAttrIsPermanent as String
    static let tokenID = kSecAttrTokenID as String
    static let privateKeyAttributes = kSecPrivateKeyAttrs as String
    static let publicKeyAttributes = kSecPublicKeyAttrs as String
    static let creationDate = kSecAttrCreationDate as String
    static let modificationDate = kSecAttrModificationDate as String
}
