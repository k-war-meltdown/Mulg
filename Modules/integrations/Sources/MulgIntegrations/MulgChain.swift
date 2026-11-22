import Foundation
import MulgContracts
import MulgIntegrationsHooks
import os
import Security

/// MulgChain: a keychain for games that can't use the real one (ad-hoc signed apps have no
/// keychain access group). Ported from upstream `MulgKeychain` in Swift 6 and made to follow
/// Apple's documented keychain behaviour where upstream did not:
///
/// - what a search returns follows `kSecReturnData`/`Attributes`/`Ref`/`PersistentRef`, alone
///   or combined, and `kSecMatchLimit` (one, all or a number) decides between one result and
///   an array; upstream mixed these up and force-unwrapped its way through missing values;
/// - `SecItemAdd` returns nothing unless asked, and reports `errSecDuplicateItem`;
/// - `SecItemUpdate` and `SecItemDelete` act on every matching item, not just the first;
///   deleting a whole class works (upstream built invalid SQL for it);
/// - keys and certificates added as references (`kSecValueRef`) are stored as their data, so
///   they can be found again; upstream stored nothing for them;
/// - keys created with `kSecAttrIsPermanent` keep their tag and label, so the game can find
///   them by tag; upstream dropped both;
/// - protected keys remain native references; requested protection and persistence failures
///   are returned to the game without substituting a weaker key.
public final class MulgChain: NSObject, KeychainBackend, @unchecked Sendable {
    public let store: MulgChainStore
    private let logger = MulgLog.logger(.integrations)
    private let debugging: Bool
    private let nativeRead: ([String: Any]) -> (OSStatus, AnyObject?)

    public init(store: MulgChainStore, debugging: Bool = false,
                nativeRead: (([String: Any]) -> (OSStatus, AnyObject?))? = nil) {
        self.store = store
        self.debugging = debugging
        self.nativeRead = nativeRead ?? { query in
            var answer: Unmanaged<CFTypeRef>?
            let status = mulg_keychain_native_copy(query as CFDictionary, &answer)
            return (status, answer?.takeRetainedValue())
        }
    }

    // MARK: SecItemCopyMatching

    public func copyMatching(_ query: [AnyHashable: Any], result: AutoreleasingUnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        result?.pointee = nil
        let query = Self.local(Self.stringKeys(query))
        if unsupportedPasswordProtection(query) { return errSecUnimplemented }
        let limit = Self.matchLimit(query)
        let rows: [KeychainRow]
        do throws(MulgChainError) {
            rows = try store.find(query, limit: limit)
        } catch {
            return status(for: error, call: "copyMatching")
        }
        guard !rows.isEmpty else {
            debug("copyMatching: not found")
            return errSecItemNotFound
        }
        let returns = Returns(query)
        do throws(MulgChainError) {
            guard let answer = try answer(for: rows, returns: returns, many: limit != 1, query: query, dataWhenUnasked: true) else {
                return errSecItemNotFound
            }
            result?.pointee = answer
            return errSecSuccess
        } catch {
            return status(for: error, call: "copyMatching")
        }
    }

    // MARK: SecItemAdd

    public func add(_ attributes: [AnyHashable: Any], result: AutoreleasingUnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        result?.pointee = nil
        var attributes = Self.local(Self.stringKeys(attributes))
        if unsupportedPasswordProtection(attributes) { return errSecUnimplemented }
        do throws(MulgChainError) { try Self.storeReferencesAsData(&attributes) }
        catch { return status(for: error, call: "add") }
        let now = Date()
        attributes[KeychainKey.creationDate] = attributes[KeychainKey.creationDate] ?? now
        attributes[KeychainKey.modificationDate] = attributes[KeychainKey.modificationDate] ?? now
        let row: KeychainRow
        do throws(MulgChainError) {
            row = try store.insert(attributes)
        } catch {
            return status(for: error, call: "add")
        }
        debug("add: stored in \(row.table.name)")
        let returns = Returns(attributes)
        if returns.any {
            do throws(MulgChainError) {
                result?.pointee = try answer(for: [row], returns: returns, many: false, query: attributes, dataWhenUnasked: false)
            } catch {
                return status(for: error, call: "add")
            }
        }
        return errSecSuccess
    }

    // MARK: SecItemUpdate

    public func update(_ query: [AnyHashable: Any], attributes attributesToUpdate: [AnyHashable: Any]) -> OSStatus {
        let query = Self.local(Self.stringKeys(query))
        var changes = Self.local(Self.stringKeys(attributesToUpdate))
        var protection = changes
        protection[KeychainKey.itemClass] = query[KeychainKey.itemClass]
        if unsupportedPasswordProtection(query) || unsupportedPasswordProtection(protection) { return errSecUnimplemented }
        guard changes[KeychainKey.itemClass] == nil || changes[KeychainKey.itemClass] as? String == query[KeychainKey.itemClass] as? String else {
            return errSecParam
        }
        do throws(MulgChainError) { try Self.storeReferencesAsData(&changes) }
        catch { return status(for: error, call: "update") }
        changes[KeychainKey.modificationDate] = changes[KeychainKey.modificationDate] ?? Date()
        do throws(MulgChainError) {
            let count = try store.mutate(query, changes: changes, nativeChanges: Self.local(Self.stringKeys(attributesToUpdate)))
            guard count > 0 else {
                debug("update: not found")
                return errSecItemNotFound
            }
            debug("update: \(count) item(s)")
            return errSecSuccess
        } catch {
            return status(for: error, call: "update")
        }
    }

    // MARK: SecItemDelete

    public func remove(_ query: [AnyHashable: Any]) -> OSStatus {
        let query = Self.local(Self.stringKeys(query))
        if unsupportedPasswordProtection(query) { return errSecUnimplemented }
        do throws(MulgChainError) {
            let count = try store.mutate(query, changes: nil)
            guard count > 0 else {
                debug("delete: not found")
                return errSecItemNotFound
            }
            debug("delete: \(count) item(s)")
            return errSecSuccess
        } catch {
            return status(for: error, call: "delete")
        }
    }

    // MARK: SecKeyCreateRandomKey

    public func createRandomKey(_ parameters: [AnyHashable: Any], failure: AutoreleasingUnsafeMutablePointer<AnyObject?>?) -> Any? {
        let parameters = Self.stringKeys(parameters)
        var privateAttributes = parameters[KeychainKey.privateKeyAttributes] as? [String: Any] ?? [:]
        let permanent = Self.isTrue(privateAttributes[KeychainKey.isPermanent]) || Self.isTrue(parameters[KeychainKey.isPermanent])
        privateAttributes[KeychainKey.isPermanent] = false
        var request = parameters
        request[KeychainKey.isPermanent] = nil
        request[KeychainKey.privateKeyAttributes] = privateAttributes
        request[kSecUseDataProtectionKeychain as String] = parameters[kSecUseDataProtectionKeychain as String] ?? true

        let protected = parameters[KeychainKey.tokenID] != nil || parameters[kSecAttrAccessControl as String] != nil
            || privateAttributes[kSecAttrAccessControl as String] != nil
        var error: Unmanaged<CFError>?
        var nativeParameters = parameters
        nativeParameters[kSecUseDataProtectionKeychain as String] = parameters[kSecUseDataProtectionKeychain as String] ?? true
        let key = mulg_keychain_native_create_key((protected ? nativeParameters : request) as CFDictionary, &error)
        guard let key else {
            let cfError = error?.takeRetainedValue()
            logger.error("MulgChain: key creation failed: \(String(describing: cfError), privacy: .public)")
            failure?.pointee = cfError
            return nil
        }
        if permanent {
            do throws(MulgChainError) {
                try persist(key: key, keyClass: kSecAttrKeyClassPrivate as String, parameters: parameters,
                            attributes: privateAttributes, native: protected)
            } catch {
                if protected { _ = mulg_keychain_native_delete([kSecValueRef as String: key] as CFDictionary) }
                let code = status(for: error, call: "createRandomKey")
                failure?.pointee = CFErrorCreate(nil, kCFErrorDomainOSStatus, Int(code), nil)
                return nil
            }
        }
        return key
    }

    // MARK: SecKeyGeneratePair (deprecated by Apple, still used by older games)

    public func generatePair(_ parameters: [AnyHashable: Any],
                             publicKey: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
                             privateKey: AutoreleasingUnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        let parameters = Self.stringKeys(parameters)
        var privateAttributes = parameters[KeychainKey.privateKeyAttributes] as? [String: Any] ?? [:]
        var publicAttributes = parameters[KeychainKey.publicKeyAttributes] as? [String: Any] ?? [:]
        let everything = Self.isTrue(parameters[KeychainKey.isPermanent])
        let privatePermanent = everything || Self.isTrue(privateAttributes[KeychainKey.isPermanent])
        let publicPermanent = everything || Self.isTrue(publicAttributes[KeychainKey.isPermanent])
        privateAttributes[KeychainKey.isPermanent] = false
        publicAttributes[KeychainKey.isPermanent] = false
        var request = parameters
        request[KeychainKey.isPermanent] = nil
        request[KeychainKey.privateKeyAttributes] = privateAttributes
        request[KeychainKey.publicKeyAttributes] = publicAttributes

        let protected = parameters[KeychainKey.tokenID] != nil || parameters[kSecAttrAccessControl as String] != nil
            || privateAttributes[kSecAttrAccessControl as String] != nil
        request[kSecUseDataProtectionKeychain as String] = parameters[kSecUseDataProtectionKeychain as String] ?? true
        if protected {
            request = parameters
            request[kSecUseDataProtectionKeychain as String] = parameters[kSecUseDataProtectionKeychain as String] ?? true
        }
        var failure: Unmanaged<CFError>?
        guard let newPrivate = mulg_keychain_native_create_key(request as CFDictionary, &failure),
              let newPublic = SecKeyCopyPublicKey(newPrivate) else {
            let error = failure?.takeRetainedValue()
            return error.map { OSStatus(CFErrorGetCode($0)) } ?? errSecParam
        }
        do throws(MulgChainError) {
            var items: [[String: Any]] = []
            if publicPermanent { items.append(try keyItem(newPublic, keyClass: kSecAttrKeyClassPublic as String, parameters: parameters, attributes: publicAttributes)) }
            if privatePermanent { items.append(try keyItem(newPrivate, keyClass: kSecAttrKeyClassPrivate as String, parameters: parameters, attributes: privateAttributes, native: protected)) }
            try store.insert(items)
        } catch {
            if protected { _ = mulg_keychain_native_delete([kSecValueRef as String: newPrivate] as CFDictionary) }
            return self.status(for: error, call: "generatePair")
        }
        publicKey?.pointee = newPublic
        privateKey?.pointee = newPrivate
        return errSecSuccess
    }

    // MARK: Results

    /// Standard accessibility uses native protected envelopes when the bridge supports them (older levels map to
    /// the nearest one at least as strong, PasswordProtection.nativePolicy). Explicit biometric/passcode
    /// access-control objects remain unsupported. iCloud sync is handled by `local`, never refused.
    func unsupportedPasswordProtection(_ attributes: [String: Any]) -> Bool {
        let itemClass = attributes[KeychainKey.itemClass] as? String
        guard itemClass == nil || itemClass == kSecClassGenericPassword as String
            || itemClass == kSecClassInternetPassword as String else { return false }
        if attributes[kSecAttrAccessControl as String] != nil { return true }
        if let requested = attributes[kSecAttrAccessible as String] {
            guard let policy = requested as? String, store.supportsPasswordAccessibility(policy) else { return true }
        }
        return false
    }

    /// MulgChain is one local store: nothing syncs. A query for synced items, or for synced-or-not
    /// (`kSecAttrSynchronizableAny`, which keychain wrappers send on every read and delete), means the local
    /// items, and an item the game asks to sync is kept locally. Refusing these (2026-10-10 and before) made
    /// the token save of such sign-in SDKs fail, so the login itself failed, by e-mail, Google or otherwise.
    static func local(_ dictionary: [String: Any]) -> [String: Any] {
        var result = dictionary
        result[KeychainKey.synchronizable] = nil
        return result
    }

    /// Which `kSecReturn…` keys a query or an add sets.
    struct Returns {
        var data = false
        var attributes = false
        var reference = false
        var persistentReference = false

        init(_ query: [String: Any]) {
            data = MulgChain.isTrue(query[KeychainKey.returnData])
            attributes = MulgChain.isTrue(query[KeychainKey.returnAttributes])
            reference = MulgChain.isTrue(query[KeychainKey.returnRef])
            persistentReference = MulgChain.isTrue(query[KeychainKey.returnPersistentRef])
        }

        var count: Int {
            [data, attributes, reference, persistentReference].filter { $0 }.count
        }

        var any: Bool { count > 0 }
    }

    /// The result object for the matched rows: one value, or an array when `many`.
    /// `dataWhenUnasked` keeps upstream's answer (the item's data) for searches that ask for
    /// nothing, which Apple leaves undefined and some games rely on.
    func answer(for rows: [KeychainRow], returns: Returns, many: Bool, query: [String: Any],
                dataWhenUnasked: Bool) throws(MulgChainError) -> AnyObject? {
        var values: [AnyObject] = []
        for row in rows {
            if let value = try value(for: row, returns: returns, query: query, dataWhenUnasked: dataWhenUnasked) {
                values.append(value)
            }
        }
        if many {
            return values.isEmpty ? nil : values as NSArray
        }
        return values.first
    }

    private func value(for row: KeychainRow, returns: Returns, query: [String: Any], dataWhenUnasked: Bool) throws(MulgChainError) -> AnyObject? {
        switch returns.count {
        case 0:
            return dataWhenUnasked ? row.values[KeychainKey.valueData] as AnyObject? : nil
        case 1 where returns.data:
            return row.values[KeychainKey.valueData] as AnyObject?
        case 1 where returns.reference:
            return try reference(for: row, query: query)
        case 1 where returns.persistentReference:
            return row.persistentReference as NSData
        default:
            let dictionary = attributes(of: row, query: query)
            if returns.data {
                dictionary[KeychainKey.valueData] = row.values[KeychainKey.valueData]
            }
            if returns.reference {
                dictionary[KeychainKey.valueRef] = try reference(for: row, query: query)
            }
            if returns.persistentReference {
                dictionary[KeychainKey.valuePersistentRef] = row.persistentReference
            }
            return dictionary
        }
    }

    /// The item's attributes without its secret, as `kSecReturnAttributes` returns them.
    private func attributes(of row: KeychainRow, query: [String: Any]) -> NSMutableDictionary {
        let dictionary = NSMutableDictionary()
        for (key, value) in row.values where !KeychainSchema.values.contains(key) {
            if (row.table.name == kSecClassGenericPassword as String || row.table.name == kSecClassInternetPassword as String),
               key == kSecAttrAccessControl as String || (key == kSecAttrAccessible as String && !store.hasPasswordProtection) { continue }
            dictionary[key] = value
        }
        dictionary[KeychainKey.itemClass] = row.table.name
        dictionary[KeychainKey.synchronizable] = NSNumber(value: false)
        return dictionary
    }

    /// A key or certificate object made from the stored data; for passwords, the data itself.
    private func reference(for row: KeychainRow, query: [String: Any]) throws(MulgChainError) -> AnyObject? {
        if row.table.name == kSecClassKey as String, let persistent = row.values[KeychainKey.valuePersistentRef] as? Data {
            var nativeQuery: [String: Any] = [kSecValuePersistentRef as String: persistent, kSecReturnRef as String: true]
            for key in [kSecUseAuthenticationContext, kSecUseAuthenticationUI, kSecUseOperationPrompt,
                        kSecUseDataProtectionKeychain] {
                nativeQuery[key as String] = query[key as String]
            }
            let (status, answer) = nativeRead(nativeQuery)
            guard status == errSecSuccess else { throw .native(status) }
            guard let answer else { throw .native(errSecDecode) }
            return answer
        }
        guard let data = row.values[KeychainKey.valueData] as? Data else { return nil }
        switch row.table.name {
        case let name where name == kSecClassKey as String:
            let options: [String: Any] = [
                KeychainKey.keyType: row.values[KeychainKey.keyType] ?? (kSecAttrKeyTypeRSA as String),
                KeychainKey.keyClass: row.values[KeychainKey.keyClass] ?? (kSecAttrKeyClassPublic as String)
            ]
            return SecKeyCreateWithData(data as CFData, options as CFDictionary, nil)
        case let name where name == kSecClassCertificate as String:
            return SecCertificateCreateWithData(nil, data as CFData)
        default:
            return data as NSData
        }
    }

    // MARK: Storing

    /// Turns `kSecValueRef` keys and certificates into data and fills in the attributes the
    /// system would have read from them, so they can be found and rebuilt later.
    static func storeReferencesAsData(_ attributes: inout [String: Any]) throws(MulgChainError) {
        guard let reference = attributes[KeychainKey.valueRef] else { return }
        let object = reference as AnyObject
        if CFGetTypeID(object) == SecKeyGetTypeID() {
            let key = object as! SecKey // swiftlint:disable:this force_cast
            if attributes[KeychainKey.valueData] == nil {
                attributes[KeychainKey.valueData] = SecKeyCopyExternalRepresentation(key, nil) as Data?
                if attributes[KeychainKey.valueData] == nil {
                    var persistent: Unmanaged<CFTypeRef>?
                    let status = mulg_keychain_native_copy([kSecValueRef as String: key, kSecReturnPersistentRef as String: true] as CFDictionary, &persistent)
                    guard status == errSecSuccess, let data = persistent?.takeRetainedValue() as? Data else {
                        throw .unavailable("key reference cannot be persisted (\(status))")
                    }
                    attributes[KeychainKey.valuePersistentRef] = data
                }
            }
            if let keyAttributes = SecKeyCopyAttributes(key) as? [String: Any] {
                for name in [KeychainKey.keyType, KeychainKey.keyClass, kSecAttrKeySizeInBits as String] where attributes[name] == nil {
                    attributes[name] = keyAttributes[name]
                }
            }
        } else if CFGetTypeID(object) == SecCertificateGetTypeID() {
            let certificate = object as! SecCertificate // swiftlint:disable:this force_cast
            if attributes[KeychainKey.valueData] == nil {
                attributes[KeychainKey.valueData] = SecCertificateCopyData(certificate) as Data
            }
            let derived: [(String, Data?)] = [
                (kSecAttrIssuer as String, SecCertificateCopyNormalizedIssuerSequence(certificate) as Data?),
                (kSecAttrSerialNumber as String, SecCertificateCopySerialNumberData(certificate, nil) as Data?),
                (kSecAttrSubject as String, SecCertificateCopyNormalizedSubjectSequence(certificate) as Data?)
            ]
            for (name, value) in derived where attributes[name] == nil {
                attributes[name] = value
            }
        }
        attributes[KeychainKey.valueRef] = nil
    }

    private func keyItem(_ key: SecKey, keyClass: String, parameters: [String: Any], attributes: [String: Any],
                         native: Bool = false) throws(MulgChainError) -> [String: Any] {
        var item = attributes
        item[KeychainKey.isPermanent] = true
        item[KeychainKey.itemClass] = kSecClassKey as String
        item[KeychainKey.keyType] = parameters[KeychainKey.keyType]
        item[KeychainKey.keyClass] = keyClass
        item[kSecAttrKeySizeInBits as String] = parameters[kSecAttrKeySizeInBits as String]
        if native {
            var reference: Unmanaged<CFTypeRef>?
            let status = mulg_keychain_native_copy([kSecValueRef as String: key, kSecReturnPersistentRef as String: true] as CFDictionary, &reference)
            guard status == errSecSuccess, let data = reference?.takeRetainedValue() as? Data else { throw .unavailable("protected key persistence failed (\(status))") }
            item[KeychainKey.valuePersistentRef] = data
        } else {
            guard let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else { throw .unavailable("permanent key cannot be persisted") }
            item[KeychainKey.valueData] = data
        }
        return item
    }

    private func persist(key: SecKey, keyClass: String, parameters: [String: Any], attributes: [String: Any],
                         native: Bool = false) throws(MulgChainError) {
        try store.insert(keyItem(key, keyClass: keyClass, parameters: parameters, attributes: attributes, native: native))
    }

    // MARK: Helpers

    private func status(for error: MulgChainError, call: String) -> OSStatus {
        switch error {
        case .native(let status):
            logger.error("MulgChain \(call, privacy: .public): native credential operation failed (\(status))")
            return status
        case .duplicate:
            debug("\(call): duplicate")
            return errSecDuplicateItem
        case .unknownClass, .invalidQuery:
            debug("\(call): invalid query")
            return errSecParam
        case .unavailable, .sqlite:
            logger.error("MulgChain \(call, privacy: .public): \(error.description, privacy: .public)")
            return errSecIO
        }
    }

    private func debug(_ message: @autoclosure () -> String) {
        guard debugging else { return }
        let text = message()
        logger.debug("MulgChain \(text, privacy: .public)")
    }

    static func stringKeys(_ dictionary: [AnyHashable: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dictionary {
            if let key = key.base as? String {
                result[key] = value
            }
        }
        return result
    }

    static func isTrue(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber: number.boolValue
        case let flag as Bool: flag
        case let text as String: text == "1" || text.lowercased() == "true"
        default: false
        }
    }

    /// `kSecMatchLimit`: 1 by default, nil for all.
    static func matchLimit(_ query: [String: Any]) -> Int? {
        switch query[KeychainKey.matchLimit] {
        case let text as String:
            text == kSecMatchLimitAll as String ? nil : 1
        case let number as NSNumber:
            max(1, number.intValue)
        default:
            1
        }
    }
}
