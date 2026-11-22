import Foundation
import CryptoKit
import SQLite3
@testable import MulgIntegrations
import Security
import Testing

@Suite("MulgChain")
struct MulgChainTests {
    @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecItemNotFound, errSecDecode])
    func nativeReadStatusIsPreservedForEveryReturnShape(_ expected: OSStatus) throws {
        var queries: [[String: Any]] = []
        let backend = MulgChain(store: chain.store, nativeRead: { query in
            queries.append(query); return (expected, nil)
        })
        let tag = Data("native-read".utf8), context = NSObject()
        try chain.store.insert([kSecClass as String: kSecClassKey as String,
            kSecAttrApplicationTag as String: tag, kSecValuePersistentRef as String: Data("native-reference".utf8)])
        for attributes in [false, true] {
            var result: AnyObject? = NSObject()
            let query: [AnyHashable: Any] = [kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag, kSecReturnRef as String: true,
                kSecReturnAttributes as String: attributes, kSecUseAuthenticationContext as String: context,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
            #expect(backend.copyMatching(query, result: &result) == expected)
            #expect(result == nil)
        }
        #expect(queries.count == 2)
        #expect(queries.allSatisfy { ($0[kSecUseAuthenticationContext as String] as? NSObject) === context })
        #expect(queries.allSatisfy { $0[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String })
    }

    @Test func failedMemberDoesNotReturnAPartialNativeReferenceArray() throws {
        let backend = MulgChain(store: chain.store, nativeRead: { _ in (errSecAuthFailed, nil) })
        for tag in ["native-a", "native-b"] {
            try chain.store.insert([kSecClass as String: kSecClassKey as String,
                kSecAttrApplicationTag as String: Data(tag.utf8), kSecValuePersistentRef as String: Data(tag.utf8)])
        }
        var result: AnyObject? = NSObject()
        #expect(backend.copyMatching([kSecClass as String: kSecClassKey, kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll], result: &result) == errSecAuthFailed)
        #expect(result == nil)
    }
    @Test func storedFiltersConstrainReadsUpdatesAndDeletesAndUnknownFiltersFailClosed() throws {
        for (account, invisible) in [("visible", false), ("hidden", true)] {
            var item = password(account: account, secret: account)
            item[kSecAttrIsInvisible as String] = invisible
            #expect(chain.add(item, result: nil) == errSecSuccess)
        }
        let base: [AnyHashable: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: "svc"]
        var hidden = base
        hidden[kSecAttrIsInvisible as String] = true
        hidden[kSecReturnData as String] = true
        #expect(find(hidden).1 as? Data == Data("hidden".utf8))
        #expect(chain.update(hidden, attributes: [kSecValueData as String: Data("changed".utf8)]) == errSecSuccess)
        var visible = base
        visible[kSecAttrIsInvisible as String] = false
        #expect(find(visible).1 as? Data == Data("visible".utf8))
        var unsupported = base
        unsupported[kSecMatchCaseInsensitive as String] = true
        #expect(find(unsupported).0 == errSecParam)
        #expect(chain.update(unsupported, attributes: [kSecValueData as String: Data()]) == errSecParam)
        #expect(chain.remove(unsupported) == errSecParam)
        unsupported = base
        unsupported[kSecAttrIsInvisible as String] = NSObject()
        #expect(chain.remove(unsupported) == errSecParam)
        #expect(chain.remove(hidden) == errSecSuccess)
        #expect(find(visible).1 as? Data == Data("visible".utf8))
        #expect(find(hidden).0 == errSecItemNotFound)
        var dataQuery = base
        dataQuery[kSecValueData as String] = Data("wrong".utf8)
        #expect(chain.remove(dataQuery) == errSecItemNotFound)
        #expect(find(visible).0 == errSecSuccess)
    }

    @Test(arguments: [false, true])
    func dataProtectionImplementationSelectorPreservesTargetedOperations(_ selected: Bool) {
        var item = password(account: "selected", secret: "original")
        item[kSecUseDataProtectionKeychain as String] = selected
        #expect(chain.add(item, result: nil) == errSecSuccess)
        #expect(chain.add(password(account: "other", secret: "untouched"), result: nil) == errSecSuccess)
        let query: [AnyHashable: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "selected", kSecAttrService as String: "svc",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: selected]
        #expect(find(query).1 as? Data == Data("original".utf8))
        #expect(chain.update(query, attributes: [kSecValueData as String: Data("updated".utf8)]) == errSecSuccess)
        #expect(find(query).1 as? Data == Data("updated".utf8))
        #expect(chain.remove(query) == errSecSuccess)
        #expect(find(query).0 == errSecItemNotFound)
        #expect(find(password(account: "other", secret: "untouched")).1 as? Data == Data("untouched".utf8))
    }

    @Test func dataProtectionSelectorDoesNotAcceptMalformedValuesOrWeakenProtection() {
        #expect(chain.add(password(account: "selected", secret: "original"), result: nil) == errSecSuccess)
        var query: [AnyHashable: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "selected", kSecAttrService as String: "svc"]
        for malformed in ["true" as Any, NSNumber(value: 2), NSObject()] {
            query[kSecUseDataProtectionKeychain as String] = malformed
            #expect(find(query).0 == errSecParam)
            #expect(chain.update(query, attributes: [kSecValueData as String: Data()]) == errSecParam)
            #expect(chain.remove(query) == errSecParam)
        }
        query[kSecUseDataProtectionKeychain as String] = true
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        #expect(find(query).0 == errSecUnimplemented)
        #expect(chain.remove(query) == errSecUnimplemented)
        #expect(find(password(account: "selected", secret: "original")).1 as? Data == Data("original".utf8))
    }

    let directory: URL
    let chain: MulgChain

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mulgchain-\(UUID().uuidString)")
        chain = MulgChain(store: MulgChainStore(databaseURL: directory.appendingPathComponent("game.db"), encryptionKey: SymmetricKey(data: Data(repeating: 7, count: 32))))
    }

    private func password(account: String, service: String = "svc", secret: String) -> [AnyHashable: Any] {
        [kSecClass as String: kSecClassGenericPassword as String,
         kSecAttrAccount as String: account,
         kSecAttrService as String: service,
         kSecValueData as String: Data(secret.utf8)]
    }

    private func find(_ query: [AnyHashable: Any]) -> (OSStatus, AnyObject?) {
        var result: AnyObject?
        let status = chain.copyMatching(query, result: &result)
        return (status, result)
    }

    @Test func passwordProtectionIsNeverSilentlyWeakened() throws {
        let plain = password(account: "protected", secret: "secret")
        var protected = plain
        protected[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        #expect(chain.add(protected, result: nil) == errSecUnimplemented)
        #expect(find(plain).0 == errSecItemNotFound)
        protected = plain
        protected[kSecAttrAccessControl as String] = try #require(SecAccessControlCreateWithFlags(nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil))
        #expect(chain.add(protected, result: nil) == errSecUnimplemented)
        #expect(find(plain).0 == errSecItemNotFound)
    }

    /// Keychain wrappers ask for synced-or-not on every read and delete, and some SDKs save tokens with sync on.
    /// Nothing syncs here: the item is kept locally and every such query finds it (sign-in kept failing).
    @Test func syncRequestsUseTheLocalStore() {
        let plain = password(account: "token", secret: "secret")
        var synced = plain
        synced[kSecAttrSynchronizable as String] = true
        #expect(chain.add(synced, result: nil) == errSecSuccess)
        #expect(chain.add(plain, result: nil) == errSecDuplicateItem)
        var query = plain
        query[kSecValueData as String] = nil
        query[kSecReturnData as String] = true
        for sync in [kSecAttrSynchronizableAny as Any, true, false] {
            query[kSecAttrSynchronizable as String] = sync
            #expect(find(query).1 as? Data == Data("secret".utf8), "\(sync)")
        }
        #expect(chain.update(query, attributes: [kSecAttrSynchronizable as String: true, kSecValueData as String: Data("new".utf8)]) == errSecSuccess)
        query[kSecReturnData as String] = nil
        query[kSecReturnAttributes as String] = true
        #expect((find(query).1 as? NSDictionary)?[kSecAttrSynchronizable] as? Bool == false)
        query[kSecReturnAttributes as String] = nil
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        #expect(chain.remove(query) == errSecSuccess)
        #expect(find(plain).0 == errSecItemNotFound)
    }

    @Test("The first call on a new database works (upstream failed it)")
    func firstCallWorks() {
        var result: AnyObject?
        #expect(chain.add(password(account: "a", secret: "one"), result: &result) == errSecSuccess)
        #expect(result == nil, "nothing is returned unless asked")
    }

    @Test("Stored data is found again by account and service")
    func roundTrip() {
        var ignored: AnyObject?
        _ = chain.add(password(account: "player's id", secret: "token"), result: &ignored)
        let (status, result) = find([kSecClass as String: kSecClassGenericPassword as String,
                                     kSecAttrAccount as String: "player's id",
                                     kSecAttrService as String: "svc",
                                     kSecReturnData as String: true])
        #expect(status == errSecSuccess)
        #expect(result as? Data == Data("token".utf8))
    }

    @Test("An empty secret is stored as empty data, not as missing")
    func emptySecret() {
        var ignored: AnyObject?
        _ = chain.add(password(account: "a", secret: ""), result: &ignored)
        let (status, result) = find([kSecClass as String: kSecClassGenericPassword as String,
                                     kSecAttrAccount as String: "a",
                                     kSecReturnData as String: true])
        #expect(status == errSecSuccess)
        #expect(result as? Data == Data())
    }

    @Test("Adding the same item twice reports a duplicate")
    func duplicate() {
        var ignored: AnyObject?
        #expect(chain.add(password(account: "a", secret: "one"), result: &ignored) == errSecSuccess)
        #expect(chain.add(password(account: "a", secret: "two"), result: &ignored) == errSecDuplicateItem)
    }

    @Test func identityUpdatesRejectCollisionsAndRollBackBulkChanges() throws {
        #expect(chain.add(password(account: "a", secret: "one"), result: nil) == errSecSuccess)
        #expect(chain.add(password(account: "b", secret: "two"), result: nil) == errSecSuccess)
        let all: [AnyHashable: Any] = [kSecClass as String: kSecClassGenericPassword]
        var first = all
        first[kSecAttrAccount as String] = "a"
        #expect(chain.update(first, attributes: [kSecAttrAccount as String: "b", kSecValueData as String: Data("bad".utf8)]) == errSecDuplicateItem)
        #expect(chain.update(all, attributes: [kSecAttrAccount as String: "merged"]) == errSecDuplicateItem)
        let rows = try chain.store.find(MulgChain.stringKeys(all), limit: nil)
        #expect(Set(rows.compactMap { $0.values[kSecAttrAccount as String] as? String }) == ["a", "b"])
        var query = first; query[kSecReturnData as String] = true
        #expect(find(query).1 as? Data == Data("one".utf8))
        #expect(chain.update(first, attributes: [kSecAttrAccount as String: "a", kSecValueData as String: Data("fresh".utf8)]) == errSecSuccess)
        #expect(find(query).1 as? Data == Data("fresh".utf8))
    }

    @Test("An account stored as a string is found when searched for as data")
    func stringMatchesData() {
        var ignored: AnyObject?
        _ = chain.add(password(account: "user", secret: "x"), result: &ignored)
        let (status, _) = find([kSecClass as String: kSecClassGenericPassword as String,
                                kSecAttrAccount as String: Data("user".utf8)])
        #expect(status == errSecSuccess)
    }

    @Test("The access group is ignored when matching")
    func accessGroupIgnored() {
        var ignored: AnyObject?
        _ = chain.add(password(account: "a", secret: "x"), result: &ignored)
        let (status, _) = find([kSecClass as String: kSecClassGenericPassword as String,
                                kSecAttrAccount as String: "a",
                                kSecAttrAccessGroup as String: "TEAMID.com.example.game"])
        #expect(status == errSecSuccess)
    }

    @Test("Attributes come back without the secret, typed, with UTF-8 text")
    func attributes() throws {
        var ignored: AnyObject?
        var item = password(account: "原神", secret: "x")
        item[kSecAttrIsInvisible as String] = true
        _ = chain.add(item, result: &ignored)
        let (status, result) = find([kSecClass as String: kSecClassGenericPassword as String,
                                     kSecAttrAccount as String: "原神",
                                     kSecReturnAttributes as String: true])
        #expect(status == errSecSuccess)
        let dictionary = try #require(result as? [String: Any])
        #expect(dictionary[kSecAttrAccount as String] as? String == "原神")
        #expect(dictionary[kSecValueData as String] == nil)
        #expect((dictionary[kSecAttrIsInvisible as String] as? NSNumber)?.boolValue == true)
        #expect(dictionary[kSecAttrCreationDate as String] is Date)
    }

    @Test("Attributes and data together come back as one dictionary")
    func attributesAndData() throws {
        var ignored: AnyObject?
        _ = chain.add(password(account: "a", secret: "secret"), result: &ignored)
        let (_, result) = find([kSecClass as String: kSecClassGenericPassword as String,
                                kSecAttrAccount as String: "a",
                                kSecReturnAttributes as String: true,
                                kSecReturnData as String: true])
        let dictionary = try #require(result as? [String: Any])
        #expect(dictionary[kSecValueData as String] as? Data == Data("secret".utf8))
    }

    @Test("Match limit all returns an array of every item of the class")
    func matchAll() throws {
        var ignored: AnyObject?
        _ = chain.add(password(account: "a", secret: "1"), result: &ignored)
        _ = chain.add(password(account: "b", secret: "2"), result: &ignored)
        let (status, result) = find([kSecClass as String: kSecClassGenericPassword as String,
                                     kSecMatchLimit as String: kSecMatchLimitAll as String,
                                     kSecReturnAttributes as String: true])
        #expect(status == errSecSuccess)
        let items = try #require(result as? [[String: Any]])
        #expect(items.count == 2)
    }

    @Test("Update changes every matching item and keeps it findable")
    func update() {
        var ignored: AnyObject?
        _ = chain.add(password(account: "a", secret: "old"), result: &ignored)
        let query: [AnyHashable: Any] = [kSecClass as String: kSecClassGenericPassword as String,
                                         kSecAttrAccount as String: "a"]
        #expect(chain.update(query, attributes: [kSecValueData as String: Data("new".utf8)]) == errSecSuccess)
        var search = query
        search[kSecReturnData as String] = true
        #expect(find(search).1 as? Data == Data("new".utf8))
    }

    @Test("Updating or deleting a missing item reports not found")
    func missing() {
        let query: [AnyHashable: Any] = [kSecClass as String: kSecClassGenericPassword as String,
                                         kSecAttrAccount as String: "nobody"]
        #expect(chain.update(query, attributes: [kSecAttrLabel as String: "x"]) == errSecItemNotFound)
        #expect(chain.remove(query) == errSecItemNotFound)
        #expect(find(query).0 == errSecItemNotFound)
    }

    @Test("Delete succeeds (upstream always reported failure) and removes the item")
    func delete() {
        var ignored: AnyObject?
        _ = chain.add(password(account: "a", secret: "x"), result: &ignored)
        let query: [AnyHashable: Any] = [kSecClass as String: kSecClassGenericPassword as String,
                                         kSecAttrAccount as String: "a"]
        #expect(chain.remove(query) == errSecSuccess)
        #expect(find(query).0 == errSecItemNotFound)
    }

    @Test("Deleting a whole class removes all its items")
    func deleteClass() {
        var ignored: AnyObject?
        _ = chain.add(password(account: "a", secret: "x"), result: &ignored)
        _ = chain.add(password(account: "b", secret: "y"), result: &ignored)
        #expect(chain.remove([kSecClass as String: kSecClassGenericPassword as String]) == errSecSuccess)
        #expect(find([kSecClass as String: kSecClassGenericPassword as String]).0 == errSecItemNotFound)
    }

    @Test("A persistent reference finds the same item")
    func persistentReference() throws {
        var ignored: AnyObject?
        _ = chain.add(password(account: "a", secret: "x"), result: &ignored)
        let (_, reference) = find([kSecClass as String: kSecClassGenericPassword as String,
                                   kSecAttrAccount as String: "a",
                                   kSecReturnPersistentRef as String: true])
        let data = try #require(reference as? Data)
        let (status, secret) = find([kSecClass as String: kSecClassGenericPassword as String,
                                     kSecValuePersistentRef as String: data,
                                     kSecReturnData as String: true])
        #expect(status == errSecSuccess)
        #expect(secret as? Data == Data("x".utf8))
    }

    @Test func referenceListsRestrictReadsUpdatesAndDeletes() throws {
        #expect(chain.add(password(account: "a", secret: "one"), result: nil) == errSecSuccess)
        #expect(chain.add(password(account: "b", secret: "two"), result: nil) == errSecSuccess)
        let reference = try #require(find([kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "a", kSecReturnPersistentRef as String: true]).1 as? Data)
        var query: [AnyHashable: Any] = [kSecMatchItemList as String: [reference], kSecReturnData as String: true]
        #expect(find(query).1 as? Data == Data("one".utf8), "class is inferred from the validated local reference")
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrAccount as String] = "b"
        #expect(chain.remove(query) == errSecItemNotFound, "reference and attributes intersect")
        query[kSecAttrAccount as String] = nil
        #expect(chain.update(query, attributes: [kSecValueData as String: Data("new".utf8)]) == errSecSuccess)
        #expect(find(query).1 as? Data == Data("new".utf8))
        #expect(chain.remove(query) == errSecSuccess)
        let remaining = try chain.store.find([kSecClass as String: kSecClassGenericPassword], limit: nil)
        #expect(remaining.count == 1)
        #expect(remaining.first?.values[kSecValueData as String] as? Data == Data("two".utf8))
    }

    @Test func unsupportedAndEmptyReferenceListsNeverWidenQueries() {
        #expect(chain.add(password(account: "safe", secret: "secret"), result: nil) == errSecSuccess)
        let lists: [Any] = [[Data](), [Data("invalid".utf8)], ["unsupported object"]]
        for list in lists {
            let query: [AnyHashable: Any] = [kSecClass as String: kSecClassGenericPassword, kSecMatchItemList as String: list]
            let expected = list is [Data] ? errSecItemNotFound : errSecParam
            #expect(find(query).0 == expected)
            #expect(chain.update(query, attributes: [kSecValueData as String: Data("bad".utf8)]) == expected)
            #expect(chain.remove(query) == expected)
        }
        #expect(find([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: "safe",
                      kSecReturnData as String: true]).1 as? Data == Data("secret".utf8))
    }

    @Test("A bad persistent reference never matches or changes another item")
    func invalidPersistentReference() {
        var ignored: AnyObject?
        #expect(chain.add(password(account: "a", secret: "x"), result: &ignored) == errSecSuccess)
        let query: [AnyHashable: Any] = [kSecClass as String: kSecClassGenericPassword as String,
                                         kSecValuePersistentRef as String: Data("invalid".utf8)]
        #expect(find(query).0 == errSecItemNotFound)
        #expect(chain.update(query, attributes: [kSecValueData as String: Data("changed".utf8)]) == errSecItemNotFound)
        #expect(chain.remove(query) == errSecItemNotFound)
        #expect(find([kSecClass as String: kSecClassGenericPassword as String,
                      kSecAttrAccount as String: "a", kSecReturnData as String: true]).1 as? Data == Data("x".utf8))
    }

    @Test func deletedPersistentReferenceCannotIdentifyAReplacementItem() throws {
        #expect(chain.add(password(account: "old", secret: "old-token"), result: nil) == errSecSuccess)
        let row = try #require(try chain.store.find([kSecClass as String: kSecClassGenericPassword], limit: 1).first)
        let reference = row.persistentReference
        try chain.store.delete([row])
        #expect(chain.add(password(account: "new", secret: "new-token"), result: nil) == errSecSuccess)
        let replacement = try #require(try chain.store.find([kSecClass as String: kSecClassGenericPassword], limit: 1).first)
        #expect(replacement.rowID == row.rowID, "exercise actual SQLite row-ID reuse")
        #expect(replacement.persistentReference != reference)
        let query: [AnyHashable: Any] = [kSecClass as String: kSecClassGenericPassword, kSecValuePersistentRef as String: reference]
        #expect(find(query).0 == errSecItemNotFound)
        #expect(chain.remove(query) == errSecItemNotFound)
        // A row snapshot held across another writer cannot delete the new item either.
        try chain.store.delete([row])
        #expect(try chain.store.find([kSecClass as String: kSecClassGenericPassword], limit: 1).count == 1)
    }

    @Test(arguments: [1, 2]) func legacyReferencesMigrateAndNeverAliasNewRows(version: Int) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var database: OpaquePointer?
        #expect(sqlite3_open(chain.store.databaseURL.path, &database) == SQLITE_OK)
        let handle = try #require(database)
        try MulgChainStore.createTables(handle)
        var secret = "'old'"
        if version == 2 {
            let sealed = try CredentialProtection.seal(.text("old"), key: SymmetricKey(data: Data(repeating: 7, count: 32)))
            let bytes = try #require({ if case .blob(let data) = sealed { return data }; return nil }())
            secret = "X'" + bytes.map { String(format: "%02x", $0) }.joined() + "'"
        }
        #expect(sqlite3_exec(handle, "INSERT INTO genp(rowid, acct, svce, v_Data) VALUES(7, 'legacy', 'svc', \(secret)); PRAGMA user_version = \(version)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        #expect(try MulgChainStore.allowsNewEncryptionKey(databaseURL: chain.store.databaseURL) == (version < 2))
        let reference = Data("mulg-earlier:genp:7".utf8)
        let query: [AnyHashable: Any] = [kSecClass as String: kSecClassGenericPassword,
                                         kSecValuePersistentRef as String: reference, kSecReturnData as String: true]
        #expect(find(query).1 as? String == "old")
        #expect(chain.remove(query) == errSecSuccess)
        #expect(chain.add(password(account: "new", secret: "different"), result: nil) == errSecSuccess)
        #expect(find(query).0 == errSecItemNotFound)
        #expect(try !MulgChainStore.allowsNewEncryptionKey(databaseURL: chain.store.databaseURL))
    }

    @Test("A permanent random key keeps its tag and can be found as a key")
    func permanentKey() throws {
        let tag = Data("com.example.game.key".utf8)
        let parameters: [AnyHashable: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom as String,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true,
                                            kSecAttrApplicationTag as String: tag]
        ]
        var failure: AnyObject?
        let key = chain.createRandomKey(parameters, failure: &failure)
        #expect(key != nil, "Key creation failed: \(String(describing: failure))")
        let (status, found) = find([kSecClass as String: kSecClassKey as String,
                                    kSecAttrApplicationTag as String: tag,
                                    kSecReturnRef as String: true])
        #expect(status == errSecSuccess)
        let object = try #require(found)
        #expect(CFGetTypeID(object) == SecKeyGetTypeID())
    }

    @Test("Permanent key creation reports a persistence failure")
    func permanentKeyCannotPretendToPersist() throws {
        let blocked = directory.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("file".utf8).write(to: blocked)
        let chain = MulgChain(store: MulgChainStore(databaseURL: blocked.appendingPathComponent("game.db"),
                                                  encryptionKey: SymmetricKey(data: Data(repeating: 7, count: 32))))
        let parameters: [AnyHashable: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                             kSecAttrKeySizeInBits as String: 256, kSecAttrIsPermanent as String: true]
        var failure: AnyObject?
        #expect(chain.createRandomKey(parameters, failure: &failure) == nil)
        #expect(failure != nil)
    }

    @Test("An unsupported hardware token is not replaced with a software key")
    func requestedProtectionIsRequired() {
        var failure: AnyObject?
        let parameters: [AnyHashable: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                             kSecAttrKeySizeInBits as String: 256, kSecAttrTokenID as String: "mulg.nonexistent-token"]
        #expect(chain.createRandomKey(parameters, failure: &failure) == nil)
        #expect(failure != nil)
    }

    @Test("A legacy credential migrates without changing its row or exposing its secret")
    func legacySecretMigration() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = chain.store.databaseURL
        var database: OpaquePointer?
        #expect(sqlite3_open(file.path, &database) == SQLITE_OK)
        let handle = try #require(database)
        try MulgChainStore.createTables(handle)
        #expect(sqlite3_exec(handle, "INSERT INTO genp (acct, svce, v_Data) VALUES ('legacy', 'svc', 'legacy-cloud-token')", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "PRAGMA user_version = 1", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        #expect(try MulgChainStore.allowsNewEncryptionKey(databaseURL: file))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: "legacy"]
        let rows = try chain.store.find(query, limit: 1)
        #expect(rows.first?.rowID == 1)
        #expect(rows.first?.values[kSecValueData as String] as? String == "legacy-cloud-token")
        let bytes = try Data(contentsOf: file)
        #expect(bytes.range(of: Data("legacy-cloud-token".utf8)) == nil)
        #expect(try !MulgChainStore.allowsNewEncryptionKey(databaseURL: file))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        let reopened = MulgChainStore(databaseURL: file, encryptionKey: SymmetricKey(data: Data(repeating: 7, count: 32)))
        #expect(try reopened.find(query, limit: 1).first?.rowID == 1)
    }

    @Test("Protected credentials authenticate their key and ciphertext")
    func authenticationAndPairRollback() throws {
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let sealed = try CredentialProtection.seal(.blob(Data("cloud-token".utf8)), key: key)
        #expect(try CredentialProtection.open(sealed, key: key) == .blob(Data("cloud-token".utf8)))
        #expect(throws: MulgChainError.self) { try CredentialProtection.open(sealed, key: SymmetricKey(data: Data(repeating: 8, count: 32))) }
        var altered = try #require({ if case .blob(let bytes) = sealed { return bytes }; return nil }())
        altered[altered.count - 1] ^= 1
        #expect(throws: MulgChainError.self) { try CredentialProtection.open(.blob(altered), key: key) }
        #expect(throws: MulgChainError.self) { try CredentialProtection.open(.blob(Data("raw".utf8)), key: key) }
        let first = [kSecClass as String: kSecClassGenericPassword as Any, kSecAttrAccount as String: "pair", kSecValueData as String: Data("one".utf8)]
        #expect(throws: MulgChainError.self) { try chain.store.insert([first, first]) }
        #expect(try chain.store.find([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: "pair"], limit: nil).isEmpty)
        #expect(chain.add(password(account: "protected", secret: "original"), result: nil) == errSecSuccess)
        let wrongKeyStore = MulgChainStore(databaseURL: chain.store.databaseURL, encryptionKey: SymmetricKey(data: Data(repeating: 8, count: 32)))
        #expect(throws: MulgChainError.self) { try wrongKeyStore.insert(first) }
        #expect(find([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: "protected", kSecReturnData as String: true]).1 as? Data == Data("original".utf8))
    }

    @Test("A locked legacy vault never becomes an empty replacement database")
    func lockedVaultIsPreserved() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let vault = chain.store.databaseURL.deletingPathExtension().appendingPathExtension("mulgVault")
        let contents = Data("locked vault fixture".utf8)
        try contents.write(to: vault)
        #expect(throws: MulgChainError.self) { try MulgChainStore.allowsNewEncryptionKey(databaseURL: chain.store.databaseURL) }
        #expect(chain.add(password(account: "a", secret: "new"), result: nil) != errSecSuccess)
        #expect(!FileManager.default.fileExists(atPath: chain.store.databaseURL.path))
        #expect(try Data(contentsOf: vault) == contents)
    }

    @Test("Unknown classes are rejected")
    func unknownClass() {
        var ignored: AnyObject?
        #expect(chain.add(["class": "nope"], result: &ignored) == errSecParam)
    }

    @Test("Match limits: one by default, all, or a number")
    func matchLimit() {
        #expect(MulgChain.matchLimit([:]) == 1)
        #expect(MulgChain.matchLimit([kSecMatchLimit as String: kSecMatchLimitOne as String]) == 1)
        #expect(MulgChain.matchLimit([kSecMatchLimit as String: kSecMatchLimitAll as String]) == nil)
        #expect(MulgChain.matchLimit([kSecMatchLimit as String: NSNumber(value: 5)]) == 5)
    }
}

@Suite("Native credential mutation recovery")
struct NativeMutationTests {
    private func item(_ tag: String) -> [String: Any] {
        [kSecClass as String: kSecClassKey as String, kSecAttrApplicationTag as String: Data(tag.utf8),
         kSecValuePersistentRef as String: Data(("native-secret-" + tag).utf8), kSecAttrLabel as String: "old"]
    }

    @Test func schemaThreeMigrationKeepsReferencesAndEncryptionKey() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("game.db"), key = SymmetricKey(data: Data(repeating: 4, count: 32))
        let row = try MulgChainStore(databaseURL: url, encryptionKey: key).insert(item("a"))
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        // Reproduce schema 3 without changing its encrypted rows or frozen legacy mapping.
        #expect(sqlite3_exec(database, "DROP TABLE _mulg_native_mutations; PRAGMA user_version = 3", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        #expect(try !MulgChainStore.allowsNewEncryptionKey(databaseURL: url))
        let migrated = MulgChainStore(databaseURL: url, encryptionKey: key)
        let query: [String: Any] = [kSecClass as String: kSecClassKey as String, kSecValuePersistentRef as String: row.persistentReference]
        let found = try #require(try migrated.find(query, limit: 1).first)
        #expect(found.persistentReference == row.persistentReference)
        #expect(found.values[kSecValuePersistentRef as String] as? Data == Data("native-secret-a".utf8))
    }

    @Test func unreplayableObjectsAreRejectedBeforeEitherStoreChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var calls = 0
        let store = MulgChainStore(databaseURL: folder.appendingPathComponent("game.db"),
            encryptionKey: SymmetricKey(data: Data(repeating: 4, count: 32)), nativeMutation: { _, _ in calls += 1; return errSecSuccess })
        let row = try store.insert(item("a"))
        let query: [String: Any] = [kSecClass as String: kSecClassKey as String, kSecValuePersistentRef as String: row.persistentReference]
        #expect(throws: MulgChainError.invalidQuery) {
            try store.mutate(query, changes: [kSecAttrLabel as String: "changed"], nativeChanges: ["unsupported": NSObject()])
        }
        #expect(calls == 0)
        #expect(try store.find(query, limit: 1).first?.values[kSecAttrLabel as String] as? String == "old")
    }

    @Test func permanentlyRejectedUpdateRestoresKeyAndKeepsUnrelatedPasswordAvailable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("game.db"), key = SymmetricKey(data: Data(repeating: 4, count: 32))
        var calls = 0
        let store = MulgChainStore(databaseURL: url, encryptionKey: key, nativeMutation: { _, _ in calls += 1; return errSecParam })
        let row = try store.insert(item("a"))
        let password = try store.insert([kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: "login", kSecValueData as String: Data("token".utf8)])
        let query: [String: Any] = [kSecClass as String: kSecClassKey as String, kSecValuePersistentRef as String: row.persistentReference]
        #expect(throws: MulgChainError.invalidQuery) { try store.mutate(query, changes: [kSecAttrLabel as String: 123]) }
        #expect(calls == 0)
        #expect(throws: MulgChainError.native(errSecParam)) { try store.mutate(query, changes: [kSecAttrLabel as String: "new"]) }
        let restored = try #require(try store.find(query, limit: 1).first)
        #expect(restored.values[kSecAttrLabel as String] as? String == row.values[kSecAttrLabel as String] as? String)
        #expect(restored.persistentReference == row.persistentReference)
        let found = try store.find([kSecClass as String: kSecClassGenericPassword as String,
            kSecValuePersistentRef as String: password.persistentReference], limit: 1)
        #expect(found.first?.values[kSecValueData as String] as? Data == Data("token".utf8))
        let reopened = MulgChainStore(databaseURL: url, encryptionKey: key, nativeMutation: { _, _ in calls += 1; return errSecParam })
        #expect(try reopened.find(query, limit: 1).first?.persistentReference == row.persistentReference)
        #expect(calls == 1)
    }

    @Test func permanentFailureAfterOneDeleteRestoresOnlyUncompletedKeys() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var deleted: Data?
        let store = MulgChainStore(databaseURL: folder.appendingPathComponent("game.db"),
            encryptionKey: SymmetricKey(data: Data(repeating: 4, count: 32)), nativeMutation: { reference, _ in
                if deleted == nil { deleted = reference; return errSecSuccess }
                return errSecParam
            })
        let first = try store.insert(item("a")), second = try store.insert(item("b"))
        let query: [String: Any] = [kSecClass as String: kSecClassKey as String,
            kSecMatchItemList as String: [first.persistentReference, second.persistentReference]]
        #expect(throws: MulgChainError.native(errSecParam)) { try store.mutate(query, changes: nil) }
        let remaining = try store.find(query, limit: nil)
        #expect(remaining.count == 1)
        #expect(remaining.first?.values[kSecValuePersistentRef as String] as? Data != deleted)
    }

    @Test func oldJournalRejectionQuarantinesOnlyItsKeysAndAllowsOtherNativeMutations() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("game.db"), key = SymmetricKey(data: Data(repeating: 4, count: 32))
        let badRef = Data("native-secret-a".utf8)
        let store = MulgChainStore(databaseURL: url, encryptionKey: key, nativeMutation: { reference, _ in
            reference == badRef ? errSecParam : errSecSuccess
        })
        let blocked = try store.insert(item("a")), available = try store.insert(item("b"))
        try store.update([blocked], changes: [kSecAttrLabel as String: "desired by old runtime"])
        let legacy = try PropertyListSerialization.data(fromPropertyList: [["reference": badRef,
            "changes": [kSecAttrLabel as String: "desired by old runtime"]]], format: .binary, options: 0)
        guard case .blob(let encrypted) = try CredentialProtection.seal(.blob(legacy), key: key) else {
            Issue.record("Expected an encrypted native intent"); return
        }
        var database: OpaquePointer?, statement: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_finalize(statement); sqlite3_close(database) }
        #expect(sqlite3_prepare_v2(database, "INSERT INTO _mulg_native_mutations (payload) VALUES (?)", -1, &statement, nil) == SQLITE_OK)
        encrypted.withUnsafeBytes { bytes in
            #expect(sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), nil) == SQLITE_OK)
            #expect(sqlite3_step(statement) == SQLITE_DONE)
        }
        let blockedQuery: [String: Any] = [kSecClass as String: kSecClassKey as String, kSecValuePersistentRef as String: blocked.persistentReference]
        #expect(throws: MulgChainError.native(errSecParam)) { try store.find(blockedQuery, limit: 1) }
        let goodQuery: [String: Any] = [kSecClass as String: kSecClassKey as String, kSecValuePersistentRef as String: available.persistentReference]
        #expect(try store.find(goodQuery, limit: 1).first?.persistentReference == available.persistentReference)
        #expect(try store.mutate(goodQuery, changes: [kSecAttrLabel as String: "allowed"]) == 1)
        #expect(try store.find(goodQuery, limit: 1).first?.values[kSecAttrLabel as String] as? String == "allowed")
        #expect(throws: MulgChainError.native(errSecParam)) { try store.mutate(blockedQuery, changes: nil) }
        #expect(try store.insert([kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: "new login", kSecValueData as String: Data("token".utf8)]).table.name == kSecClassGenericPassword as String)
    }

    @Test func failedNativeUpdatesAreEncryptedAndReplayedBeforeReads() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("game.db"), key = SymmetricKey(data: Data(repeating: 4, count: 32))
        let store = MulgChainStore(databaseURL: url, encryptionKey: key, nativeMutation: { _, _ in errSecInteractionNotAllowed })
        let row = try store.insert(item("a"))
        let query: [String: Any] = [kSecClass as String: kSecClassKey as String, kSecValuePersistentRef as String: row.persistentReference]
        #expect(throws: MulgChainError.native(errSecInteractionNotAllowed)) {
            try store.mutate(query, changes: [kSecAttrLabel as String: "new"])
        }
        #expect(throws: MulgChainError.native(errSecInteractionNotAllowed)) { try store.find(query, limit: 1) }
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("native-secret-a"))
        var calls = 0
        let reopened = MulgChainStore(databaseURL: url, encryptionKey: key, nativeMutation: { reference, changes in
            calls += 1
            #expect(reference == Data("native-secret-a".utf8))
            #expect(changes?[kSecAttrLabel as String] as? String == "new")
            return errSecSuccess
        })
        let found = try #require(try reopened.find(query, limit: 1).first)
        #expect(calls == 1 && found.persistentReference == row.persistentReference)
        #expect(found.values[kSecAttrLabel as String] as? String == "new")
        _ = try reopened.find(query, limit: 1)
        #expect(calls == 1)
    }

    @Test(arguments: [errSecMissingEntitlement, errSecNoSuchKeychain, errSecNotAvailable])
    func keychainWallRefusalDoesNotBlockLaterCalls(status: OSStatus) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("game.db"), key = SymmetricKey(data: Data(repeating: 4, count: 32))
        let store = MulgChainStore(databaseURL: url, encryptionKey: key, nativeMutation: { _, _ in status })
        let row = try store.insert(item("a"))
        let query: [String: Any] = [kSecClass as String: kSecClassKey as String, kSecValuePersistentRef as String: row.persistentReference]
        #expect(throws: MulgChainError.native(status)) { try store.mutate(query, changes: [kSecAttrLabel as String: "new"]) }
        // The refused change is rolled back and dropped from the queue: the key reads as before, and other calls work.
        let found = try #require(try store.find(query, limit: 1).first)
        #expect(found.values[kSecAttrLabel as String] as? String != "new")
        #expect(try store.insert([kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: "login", kSecValueData as String: Data("token".utf8)]).table.name == kSecClassGenericPassword as String)
    }

    @Test func duplicateValidationPrecedesNativeChangesAndDeleteReplayIsIdempotent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var calls = 0
        let store = MulgChainStore(databaseURL: folder.appendingPathComponent("game.db"),
            encryptionKey: SymmetricKey(data: Data(repeating: 4, count: 32)), nativeMutation: { _, changes in
                calls += 1
                return changes == nil ? errSecItemNotFound : errSecSuccess
            })
        let first = try store.insert(item("a"))
        _ = try store.insert(item("b"))
        let query: [String: Any] = [kSecClass as String: kSecClassKey as String, kSecValuePersistentRef as String: first.persistentReference]
        #expect(throws: MulgChainError.duplicate) { try store.mutate(query, changes: [kSecAttrApplicationTag as String: Data("b".utf8)]) }
        #expect(calls == 0)
        #expect(try store.mutate(query, changes: nil) == 1)
        #expect(try store.find(query, limit: 1).isEmpty)
        #expect(calls == 1)
    }

    @Test func partiallyCompletedNativeDeletesRecoverWithoutRevivingRows() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("game.db"), key = SymmetricKey(data: Data(repeating: 4, count: 32))
        var deleted: Set<Data> = []
        var blocked = true
        let store = MulgChainStore(databaseURL: url, encryptionKey: key, nativeMutation: { reference, _ in
            if deleted.contains(reference) { return errSecItemNotFound }
            if blocked && !deleted.isEmpty { return errSecInteractionNotAllowed }
            deleted.insert(reference)
            return errSecSuccess
        })
        let first = try store.insert(item("a")), second = try store.insert(item("b"))
        let query: [String: Any] = [kSecClass as String: kSecClassKey as String,
            kSecMatchItemList as String: [first.persistentReference, second.persistentReference]]
        #expect(throws: MulgChainError.native(errSecInteractionNotAllowed)) { try store.mutate(query, changes: nil) }
        #expect(deleted.count == 1)
        blocked = false
        #expect(try store.find(query, limit: nil).isEmpty)
        #expect(deleted.count == 2)
    }
}

@Suite("MulgChain values")
struct MulgChainValueTests {
    @Test func booleansAreNotNumbers() {
        #expect(SQLValue.from(true) == .text("1"))
        #expect(SQLValue.from(NSNumber(value: 443)) == .text("443"))
        #expect(SQLValue.from("x") == .text("x"))
        #expect(SQLValue.from(Data([1, 2])) == .blob(Data([1, 2])))
        #expect(SQLValue.from(nil) == .null)
    }

    @Test func readBackTyped() {
        #expect((SQLValue.text("443").attributeValue(column: kSecAttrPort as String) as? NSNumber)?.intValue == 443)
        #expect(SQLValue.text("443").attributeValue(column: kSecAttrAccount as String) as? String == "443")
    }

    @Test func matchClauseSkipsAccessGroupAndQuotes() throws {
        let table = try #require(KeychainSchema.tables[kSecClassGenericPassword as String])
        let clause = try MulgChainStore.matchClause(table: table, query: [
            kSecAttrAccessGroup as String: "group", kSecAttrAccount as String: "a", kSecAttrDescription as String: "d"
        ])
        #expect(!clause.sql.contains("agrp"))
        #expect(clause.sql.contains("\"acct\""))
        #expect(clause.sql.contains("\"desc\""))
        #expect(clause.bindings == [.text("a"), .text("d")])
    }

    @Test func persistentReferences() {
        let data = PersistentReference.make(table: "genp", rowID: 42)
        #expect(PersistentReference.rowID(from: data, table: "genp") == 42)
        #expect(PersistentReference.rowID(from: data, table: "keys") == nil)
        #expect(PersistentReference.rowID(from: Data("other".utf8), table: "genp") == nil)
        // References handed out under an earlier name still resolve.
        #expect(PersistentReference.rowID(from: Data("mulg-earlier:genp:7".utf8), table: "genp") == 7)
        #expect(PersistentReference.rowID(from: Data("mulg-earlier:keys:7".utf8), table: "genp") == nil)
        // Not a reference: another product's prefix, extra parts, and the stable v3 format (even one that
        // looks like a number).
        #expect(PersistentReference.rowID(from: Data("other:genp:7".utf8), table: "genp") == nil)
        #expect(PersistentReference.rowID(from: Data("mulg-chain:genp:7:8".utf8), table: "genp") == nil)
        #expect(PersistentReference.rowID(from: Data("mulg-chain-v3:genp:00000000000000000000000000000007".utf8), table: "genp") == nil)
    }
}
