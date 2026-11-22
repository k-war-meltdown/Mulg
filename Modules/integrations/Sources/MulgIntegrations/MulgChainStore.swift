import Foundation
import CryptoKit
import MulgContracts
import SQLite3
import Security
import MulgIntegrationsHooks

/// Why a MulgChain database operation failed.
public enum MulgChainError: Error, Equatable, CustomStringConvertible {
    /// The database file could not be opened or created.
    case unavailable(String)
    /// The query has no item class, or one MulgChain does not store.
    case unknownClass
    case invalidQuery
    /// An item with the same primary attributes already exists.
    case duplicate
    case sqlite(String)
    case native(Int32)

    public var description: String {
        switch self {
        case .unavailable(let reason): "MulgChain database unavailable: \(reason)"
        case .unknownClass: "unknown keychain item class"
        case .invalidQuery: "unsupported keychain query"
        case .duplicate: "duplicate keychain item"
        case .sqlite(let message): "MulgChain database error: \(message)"
        case .native(let status): "native credential operation failed (\(status))"
        }
    }
}

/// One stored keychain item.
public struct KeychainRow {
    public let rowID: Int64
    public let identifier: String
    public var persistentReference: Data { PersistentReference.make(table: table.name, identifier: identifier) }
    public let table: KeychainSchema.Table
    /// Column values, typed as the game stored them (String, Data, NSNumber or Date).
    public var values: [String: Any]
}

/// A value as SQLite stores it. The columns are TEXT, so numbers are kept as text; reading
/// back converts them to the attribute's type (`KeychainSchema.integerAttributes` and so on).
enum SQLValue: Equatable {
    case text(String)
    case blob(Data)
    case null

    /// Converts an attribute value to what goes into the database. Objects the database can't
    /// hold (access control, key and certificate references) become NULL, as upstream did;
    /// `MulgChain` turns key and certificate references into data before storing them.
    static func from(_ value: Any?) -> SQLValue {
        guard let value else { return .null }
        switch value {
        case let string as String:
            return .text(string)
        case let data as Data:
            return .blob(data)
        case let date as Date:
            return .text(String(date.timeIntervalSinceReferenceDate))
        case let number as NSNumber:
            // Booleans are NSNumbers too; only the CoreFoundation type tells them apart.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .text(number.boolValue ? "1" : "0")
            }
            return .text(number.stringValue)
        default:
            return .null
        }
    }

    /// Reads a stored value back as the type the attribute has.
    func attributeValue(column: String) -> Any? {
        switch self {
        case .null:
            return nil
        case .blob(let data):
            return data
        case .text(let text):
            if KeychainSchema.integerAttributes.contains(column), let number = Int(text) {
                return NSNumber(value: number)
            }
            if KeychainSchema.booleanAttributes.contains(column) {
                return NSNumber(value: text == "1" || text.lowercased() == "true")
            }
            if KeychainSchema.dateAttributes.contains(column), let seconds = Double(text) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            return text
        }
    }
}

/// The SQLite file behind MulgChain, one per game, in the upstream location with the same
/// columns (`~/Library/Containers/io.mulg.Mulg/MulgChain/<bundle id>.db`). Schema 2 encrypts
/// secrets and native persistent references; the bridge supplies its system-Keychain key.
///
/// Fixes over upstream's `MulgKeychainDB`:
/// - the very first call after the file was created failed, because a new file was closed
///   again before its tables were made;
/// - values were pasted into the SQL text, so an apostrophe in an account name broke the
///   query and non-UTF-8 data crashed the game; every value is now a bound parameter;
/// - text was read back as ASCII, garbling non-English account names; it is UTF-8 now;
/// - numbers, booleans and dates were stored as NULL; they are stored and read back typed;
/// - `delete` always reported failure (it expected SQLITE_OK from a finished statement);
/// - adding an item twice stored it twice (NULL primary keys are never equal in SQLite), and
///   later reads returned the stale copy; adding now reports a duplicate, and reads return
///   the newest row first for databases that already hold copies;
/// - the file was opened and closed on every call; it now stays open.
public final class MulgChainStore: @unchecked Sendable {
    public let databaseURL: URL
    /// Schema 4 journals native mutations; schema 3 identities and legacy mappings stay intact.
    public static let schemaVersion = 4

    private let lock = NSLock()
    // Guarded by `lock`.
    private var connection: OpaquePointer?
    private var encryptionKey: SymmetricKey?
    private var rejectedNativeReferences: [Data: Int32] = [:] // Legacy intents without rollback snapshots.
    private let nativeMutation: (Data, [String: Any]?) -> Int32
    private let passwordProtection: PasswordProtection?
    var hasPasswordProtection: Bool { passwordProtection != nil }
    func supportsPasswordAccessibility(_ policy: String) -> Bool {
        passwordProtection != nil && PasswordProtection.nativePolicy(for: policy) != nil
    }

    public init(databaseURL: URL, encryptionKey: SymmetricKey? = nil,
                passwordProtection: PasswordProtection? = nil, nativeMutation: ((Data, [String: Any]?) -> Int32)? = nil) {
        self.databaseURL = databaseURL
        self.encryptionKey = encryptionKey
        self.passwordProtection = passwordProtection
        self.nativeMutation = nativeMutation ?? { reference, changes in
            let query = [kSecValuePersistentRef as String: reference] as CFDictionary
            return changes.map { mulg_keychain_native_update(query, $0 as CFDictionary) }
                ?? mulg_keychain_native_delete(query)
        }
    }

    deinit {
        if let connection {
            sqlite3_close_v2(connection)
        }
    }

    // MARK: Queries

    /// Never replace a missing key for an already encrypted database with an unrelated new key.
    public static func allowsNewEncryptionKey(databaseURL: URL) throws(MulgChainError) -> Bool {
        let vault = databaseURL.deletingPathExtension().appendingPathExtension(ContainerPaths.legacyVaultExtension)
        guard !FileManager.default.fileExists(atPath: vault.path) else { throw .unavailable("credential vault is still locked") }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return true }
        var database: OpaquePointer?
        let status = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close_v2(database) }
        guard status == SQLITE_OK, let database else { throw .unavailable("could not read credential protection version") }
        return try schema(database) < 2 // Schema 2 already encrypts secrets and must keep its key.
    }

    private static func schema(_ database: OpaquePointer) throws(MulgChainError) -> Int32 {
        let statement = try prepare(database, "PRAGMA user_version", bindings: [])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw .sqlite(message(database)) }
        return sqlite3_column_int(statement, 0)
    }

    /// Items of the query's class whose attributes match, newest first. `limit` nil means all.
    public func find(_ query: [String: Any], limit: Int?) throws(MulgChainError) -> [KeychainRow] {
        let table = try Self.queryTable(query)
        return try withConnection { database throws(MulgChainError) in
            let rows = try Self.select(database, table: table, query: query, limit: limit, key: encryptionKey, passwordProtection: passwordProtection)
            try ensureNativeRowsAvailable(rows)
            return rows
        }
    }

    private static func queryTable(_ query: [String: Any]) throws(MulgChainError) -> KeychainSchema.Table {
        var itemClass = query[KeychainKey.itemClass]
        if itemClass == nil {
            let references = query[KeychainKey.matchItemList] as? [Data]
                ?? (query[KeychainKey.valuePersistentRef] as? Data).map { [$0] } ?? []
            let classes = KeychainSchema.tables.keys.filter { name in
                references.contains { PersistentReference.identity(from: $0, table: name) != nil }
            }
            if classes.count == 1 { itemClass = classes[0] }
        }
        guard let table = KeychainSchema.table(for: itemClass) else {
            throw .unknownClass
        }
        return table
    }

    /// Stores a new item. Throws `.duplicate` when one with the same primary attributes exists.
    @discardableResult
    public func insert(_ attributes: [String: Any]) throws(MulgChainError) -> KeychainRow {
        try withConnection { database throws(MulgChainError) in
            try Self.transaction(database) { () throws(MulgChainError) in try insert(attributes, into: database) }
        }
    }

    /// A permanent key pair either persists together or leaves the old database intact.
    public func insert(_ items: [[String: Any]]) throws(MulgChainError) {
        guard !items.isEmpty else { return }
        try withConnection { database throws(MulgChainError) in
            try Self.transaction(database) { () throws(MulgChainError) in
                for item in items { _ = try insert(item, into: database) }
            }
        }
    }

    private func insert(_ attributes: [String: Any], into database: OpaquePointer) throws(MulgChainError) -> KeychainRow {
        guard let table = KeychainSchema.table(for: attributes[KeychainKey.itemClass]) else { throw .unknownClass }
        if table.name == kSecClassKey as String { try ensureNativeReferenceAvailable(attributes[KeychainKey.valuePersistentRef] as? Data) }
        if try Self.existingIdentity(database, table: table, attributes: attributes) {
            throw .duplicate
        }
        let columns = table.columns.filter { attributes[$0] != nil }
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let names = (["_mulg_ref"] + columns).map(Self.quoted).joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: columns.count + 1).joined(separator: ", ")
        let sql = "INSERT INTO \(Self.quoted(table.name)) (\(names)) VALUES (\(placeholders))"
        let bindings = try columns.map { column throws(MulgChainError) -> SQLValue in try protectedValue(attributes[column], column: column, attributes: attributes) }
        try Self.execute(database, sql, bindings: [.text(identifier)] + bindings)
        var values: [String: Any] = [:]
        for column in columns {
            values[column] = SQLValue.from(attributes[column]).attributeValue(column: column)
        }
        return KeychainRow(rowID: sqlite3_last_insert_rowid(database), identifier: identifier, table: table, values: values)
    }

    /// Changes stored items. Only attributes the table has are written.
    public func update(_ rows: [KeychainRow], changes: [String: Any]) throws(MulgChainError) {
        try withConnection { database throws(MulgChainError) in
            try Self.transaction(database) { () throws(MulgChainError) in
                try updateRows(rows, changes: changes, database: database)
            }
        }
    }

    private func updateRows(_ rows: [KeychainRow], changes: [String: Any], database: OpaquePointer) throws(MulgChainError) {
        try ensureNativeRowsAvailable(rows)
        guard let table = rows.first?.table else { return }
        var columns = table.columns.filter { changes.keys.contains($0) }
        // Changing a password's access policy also rewraps its existing secret atomically.
        if [kSecClassGenericPassword as String, kSecClassInternetPassword as String].contains(table.name),
           changes[kSecAttrAccessible as String] != nil, !columns.contains(KeychainKey.valueData) {
            columns.append(KeychainKey.valueData)
        }
        guard !columns.isEmpty else { return }
        let assignments = columns.map { "\(Self.quoted($0)) = ?" }.joined(separator: ", ")
        let sql = "UPDATE \(Self.quoted(table.name)) SET \(assignments) WHERE _mulg_ref = ?"
        for row in rows {
            // Read inside the write transaction: another writer may have changed the
            // identity since the query returned its snapshot.
            guard let current = try Self.select(database, table: table,
                query: [KeychainKey.valuePersistentRef: row.persistentReference], limit: 1,
                key: encryptionKey, passwordProtection: passwordProtection).first else { continue }
            try ensureNativeRowsAvailable([current])
            var identity = current.values
            for column in columns {
                identity[column] = SQLValue.from(changes[column]).attributeValue(column: column)
            }
            let identityChanged = table.primaries.filter { !KeychainSchema.unmatchedPrimaries.contains($0) }
                .contains { SQLValue.from(current.values[$0]) != SQLValue.from(identity[$0]) }
            if identityChanged, try Self.existingIdentity(database, table: table, attributes: identity, excluding: row.identifier) {
                throw .duplicate
            }
            var bindings = try columns.map { column throws(MulgChainError) -> SQLValue in
                let value = column == KeychainKey.valueData && changes[column] == nil ? current.values[column] : changes[column]
                return try protectedValue(value, column: column, attributes: identity, itemClass: table.name)
            }
            bindings.append(.text(row.identifier))
            try Self.execute(database, sql, bindings: bindings)
        }
    }

    /// Matching, duplicate validation, desired metadata and encrypted native intent commit
    /// together. Native replay checkpoints completed keys and restores uncompleted metadata on
    /// permanent rejection; transient failures keep access blocked instead of exposing split state.
    func mutate(_ query: [String: Any], changes: [String: Any]?, nativeChanges: [String: Any]? = nil) throws(MulgChainError) -> Int {
        let table = try Self.queryTable(query)
        return try withConnection { database throws(MulgChainError) in
            let count = try Self.transaction(database) { () throws(MulgChainError) -> Int in
                let rows = try Self.select(database, table: table, query: query, limit: nil, key: encryptionKey, passwordProtection: passwordProtection, unwrapPasswords: changes != nil || query[KeychainKey.valueData] != nil)
                try ensureNativeRowsAvailable(rows)
                guard !rows.isEmpty else { return 0 }
                var operations: [[String: Any]] = []
                for row in rows where row.table.name == kSecClassKey as String {
                    guard let reference = row.values[KeychainKey.valuePersistentRef] as? Data else { continue }
                    var operation: [String: Any] = ["reference": reference, "before": row.values,
                                                    "identifier": row.identifier, "rowID": NSNumber(value: row.rowID)]
                    if let changes {
                        let native = nativeChanges ?? changes
                        try Self.validateNativeChanges(native)
                        operation["changes"] = native
                    }
                    operations.append(operation)
                }
                if !operations.isEmpty {
                    let data: Data
                    do { data = try PropertyListSerialization.data(fromPropertyList: operations, format: .binary, options: 0) }
                    catch { throw .invalidQuery }
                    guard let key = encryptionKey else { throw .unavailable("credential protection key missing") }
                    try Self.execute(database, "INSERT INTO _mulg_native_mutations (payload) VALUES (?)",
                                     bindings: [try CredentialProtection.seal(.blob(data), key: key)])
                }
                if let changes { try updateRows(rows, changes: changes, database: database) }
                else {
                    for row in rows {
                        try Self.execute(database, "DELETE FROM \(Self.quoted(table.name)) WHERE _mulg_ref = ?", bindings: [.text(row.identifier)])
                    }
                }
                return rows.count
            }
            try reconcileNativeMutations(database)
            return count
        }
    }

    private func reconcileNativeMutations(_ database: OpaquePointer) throws(MulgChainError) {
        rejectedNativeReferences.removeAll(keepingCapacity: true)
        let statement = try Self.prepare(database, "SELECT rowid, payload FROM _mulg_native_mutations ORDER BY rowid", bindings: [])
        defer { sqlite3_finalize(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW, let key = encryptionKey else { throw .unavailable("native mutation journal unavailable") }
            guard case .blob(let data) = try CredentialProtection.open(Self.column(statement, 1), key: key),
                  var operations = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String: Any]] else {
                throw .unavailable("native mutation journal is corrupt")
            }
            let rowID = sqlite3_column_int64(statement, 0)
            while let operation = operations.first {
                guard let reference = operation["reference"] as? Data else { throw .invalidQuery }
                let changes = operation["changes"] as? [String: Any]
                let status = nativeMutation(reference, changes)
                guard status == errSecSuccess || (changes == nil && status == errSecItemNotFound) else {
                    if Self.permanentNativeRejection(status) {
                        if operations.allSatisfy({ $0["before"] is [String: Any] }) {
                            try Self.transaction(database) { () throws(MulgChainError) in
                                for pending in operations { try restoreNativeMetadata(pending, database: database) }
                                try saveNativeOperations([], rowID: rowID, database: database)
                            }
                        } else {
                            // Schema-4 intents written by older runtimes have no before state.
                            // Keep those affected keys unavailable without blocking other keys/passwords.
                            for pending in operations {
                                guard let reference = pending["reference"] as? Data else { throw .invalidQuery }
                                rejectedNativeReferences[reference] = status
                            }
                            break
                        }
                    }
                    throw .native(status)
                }
                operations.removeFirst()
                try saveNativeOperations(operations, rowID: rowID, database: database)
            }
        }
    }

    /// Statuses that will not change on a retry. The keychain wall (2026-10-10) refuses the game's native calls
    /// for good (missing entitlement, no keychain, not available). Counted as transient, one queued change
    /// behind the wall blocked every later credential call of the game. A locked keychain (interaction not
    /// allowed) stays transient: it opens again.
    static func permanentNativeRejection(_ status: Int32) -> Bool {
        [errSecParam, errSecDuplicateItem, errSecUnimplemented, errSecItemNotFound, errSecDecode,
         errSecMissingEntitlement, errSecNoSuchKeychain, errSecNotAvailable].contains(status)
    }

    private func ensureNativeReferenceAvailable(_ reference: Data?) throws(MulgChainError) {
        if let reference, let status = rejectedNativeReferences[reference] { throw .native(status) }
    }

    private func ensureNativeRowsAvailable(_ rows: [KeychainRow]) throws(MulgChainError) {
        for row in rows where row.table.name == kSecClassKey as String {
            try ensureNativeReferenceAvailable(row.values[KeychainKey.valuePersistentRef] as? Data)
        }
    }

    private static func validateNativeChanges(_ changes: [String: Any]) throws(MulgChainError) {
        let dataAttributes = [kSecAttrApplicationLabel, kSecAttrApplicationTag, kSecValueData, kSecValuePersistentRef].map { $0 as String }
        for (name, value) in changes {
            let valid: Bool
            if dataAttributes.contains(name) { valid = value is Data }
            else if name == KeychainKey.keyType || name == KeychainKey.keyClass || name == kSecAttrLabel as String
                || name == kSecAttrAccessible as String || name == kSecAttrAccessGroup as String { valid = value is String }
            else if KeychainSchema.booleanAttributes.contains(name) || KeychainSchema.integerAttributes.contains(name) { valid = value is NSNumber }
            else if KeychainSchema.dateAttributes.contains(name) { valid = value is Date }
            else { valid = PropertyListSerialization.propertyList(changes, isValidFor: .binary) }
            guard valid else { throw .invalidQuery }
        }
    }

    private func saveNativeOperations(_ operations: [[String: Any]], rowID: Int64, database: OpaquePointer) throws(MulgChainError) {
        if operations.isEmpty {
            try Self.execute(database, "DELETE FROM _mulg_native_mutations WHERE rowid = ?", bindings: [.text(String(rowID))])
        } else {
            guard let key = encryptionKey else { throw .unavailable("credential protection key missing") }
            let data: Data
            do { data = try PropertyListSerialization.data(fromPropertyList: operations, format: .binary, options: 0) }
            catch { throw .invalidQuery }
            try Self.execute(database, "UPDATE _mulg_native_mutations SET payload = ? WHERE rowid = ?",
                bindings: [try CredentialProtection.seal(.blob(data), key: key), .text(String(rowID))])
        }
    }

    private func restoreNativeMetadata(_ operation: [String: Any], database: OpaquePointer) throws(MulgChainError) {
        guard let values = operation["before"] as? [String: Any], let identifier = operation["identifier"] as? String,
              let rowID = operation["rowID"] as? NSNumber, let table = KeychainSchema.tables[kSecClassKey as String]
        else { throw .unavailable("native mutation recovery metadata missing") }
        try Self.execute(database, "DELETE FROM \(Self.quoted(table.name)) WHERE _mulg_ref = ?", bindings: [.text(identifier)])
        let names = (["rowid", "_mulg_ref"] + table.columns).map(Self.quoted).joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: table.columns.count + 2).joined(separator: ", ")
        let bindings = try table.columns.map { column throws(MulgChainError) -> SQLValue in try protectedValue(values[column], column: column) }
        try Self.execute(database, "INSERT INTO \(Self.quoted(table.name)) (\(names)) VALUES (\(placeholders))",
                         bindings: [.text(rowID.stringValue), .text(identifier)] + bindings)
    }

    public func delete(_ rows: [KeychainRow]) throws(MulgChainError) {
        guard let table = rows.first?.table else { return }
        let sql = "DELETE FROM \(Self.quoted(table.name)) WHERE _mulg_ref = ?"
        try withConnection { database throws(MulgChainError) in
            try ensureNativeRowsAvailable(rows)
            try Self.transaction(database) { () throws(MulgChainError) in
                for row in rows {
                    try Self.execute(database, sql, bindings: [.text(row.identifier)])
                }
            }
        }
    }

    // MARK: Matching

    /// The WHERE clause for a query: every primary attribute (but the access group) and the
    /// stored attributes the query gives. Values compare as bytes, so a name stored as a
    /// string matches the same name searched for as data, as upstream's LIKE did (without
    /// LIKE's wildcards and case folding).
    static func matchClause(table: KeychainSchema.Table, query: [String: Any]) throws(MulgChainError) -> (sql: String, bindings: [SQLValue]) {
        var conditions: [String] = []
        var bindings: [SQLValue] = []
        func referenceCondition(_ reference: Any) -> String {
            switch PersistentReference.identity(from: reference, table: table.name) {
            case .stable(let identifier):
                bindings.append(.text(identifier))
                return "_mulg_ref = ?"
            case .legacy(let rowID):
                bindings += [.text(table.name), .text(String(rowID))]
                return "_mulg_ref IN (SELECT reference FROM _mulg_legacy_refs WHERE item_class = ? AND legacy_rowid = ?)"
            case nil:
                // A bad reference must not turn an update or delete into a class-wide match.
                return "0 = 1"
            }
        }
        if let reference = query[KeychainKey.valuePersistentRef] {
            conditions.append(referenceCondition(reference))
        }
        if let list = query[KeychainKey.matchItemList] {
            guard let references = list as? [Data] else { throw .invalidQuery }
            conditions.append(references.isEmpty ? "0 = 1" : "(" + references.map(referenceCondition).joined(separator: " OR ") + ")")
        }
        // Object references are not local row identities. Never silently widen their query.
        if query[KeychainKey.valueRef] != nil { throw .invalidQuery }
        let candidates = (table.primaries + table.attributes).filter { !KeychainSchema.unmatchedPrimaries.contains($0) }
        // Only nonrestrictive return/authentication options may be ignored. Unknown predicates
        // must never turn a targeted update/delete into a broader match.
        let options = Set([KeychainKey.itemClass, KeychainKey.matchLimit, KeychainKey.matchItemList,
            KeychainKey.returnData, KeychainKey.returnAttributes, KeychainKey.returnRef,
            KeychainKey.returnPersistentRef, KeychainKey.valuePersistentRef, KeychainKey.valueData,
            kSecUseAuthenticationContext as String, kSecUseAuthenticationUI as String,
            kSecUseOperationPrompt as String])
        if let data = query[KeychainKey.valueData], !(data is Data) { throw .invalidQuery }
        let allowed = Set(candidates).union(options).union(KeychainSchema.unmatchedPrimaries)
        for (name, value) in query where !allowed.contains(name) {
            // This chooses Security's implementation, not an item predicate. MulgChain
            // already owns these operations through its encrypted per-game store. Accept
            // the standard Boolean selector without dropping any matching or protection
            // attributes; lock-state, access-control and sync requests retain their checks.
            if name == kSecUseDataProtectionKeychain as String {
                guard let flag = value as? NSNumber,
                      CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw .invalidQuery }
                continue
            }
            // The store is local; false requests no synchronization and adds no predicate.
            guard name == KeychainKey.synchronizable, let flag = value as? NSNumber,
                  !flag.boolValue else { throw .invalidQuery }
        }
        for column in candidates {
            guard let supplied = query[column] else { continue }
            let value = SQLValue.from(supplied)
            guard value != .null else { throw .invalidQuery }
            conditions.append("CAST(\(quoted(column)) AS BLOB) = CAST(? AS BLOB)")
            bindings.append(value)
        }
        return (conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND "), bindings)
    }

    private static func select(_ database: OpaquePointer, table: KeychainSchema.Table, query: [String: Any],
                               limit: Int?, key: SymmetricKey?, passwordProtection: PasswordProtection? = nil, unwrapPasswords: Bool = true, allowPlaintext: Bool = false,
                               legacyLayout: Bool = false) throws(MulgChainError) -> [KeychainRow] {
        let clause = try matchClause(table: table, query: query)
        var sql = "SELECT rowid, * FROM \(quoted(table.name)) \(clause.sql) ORDER BY rowid DESC"
        if let limit, query[KeychainKey.valueData] == nil {
            sql += " LIMIT \(max(1, limit))"
        }
        let statement = try prepare(database, sql, bindings: clause.bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [KeychainRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw .sqlite(message(database)) }
            let rowID = sqlite3_column_int64(statement, 0)
            var values: [String: Any] = [:]
            var identifier = ""
            for index in 1..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                let stored = column(statement, index)
                if name == "_mulg_ref" {
                    if case .text(let value) = stored { identifier = value }
                    continue
                }
                let decoded: SQLValue
                if [KeychainKey.valueData, KeychainKey.valuePersistentRef].contains(name), let key {
                    decoded = try CredentialProtection.open(stored, key: key, allowPlaintext: allowPlaintext)
                }
                else { decoded = stored }
                if let value = decoded.attributeValue(column: name) {
                    values[name] = value
                }
            }
            if unwrapPasswords, [kSecClassGenericPassword as String, kSecClassInternetPassword as String].contains(table.name),
               let policy = values[kSecAttrAccessible as String] as? String {
                let stored = SQLValue.from(values[KeychainKey.valueData])
                if PasswordProtection.isEnvelope(stored) {
                    guard let passwordProtection else { throw .native(errSecUnimplemented) }
                    let opened = try passwordProtection.open(stored, accessibility: policy)
                    values[KeychainKey.valueData] = opened.attributeValue(column: KeychainKey.valueData)
                } else if passwordProtection != nil, stored != .null {
                    // Older rows with policy metadata lack native protection. Require re-login,
                    // rather than claiming those bytes satisfy the requested policy.
                    throw .native(errSecDecode)
                }
            }
            guard legacyLayout || !identifier.isEmpty else { throw .sqlite("credential identity missing") }
            // Data is encrypted at rest, so compare only after decryption and before the limit.
            if let expected = query[KeychainKey.valueData] as? Data,
               SQLValue.from(values[KeychainKey.valueData]) != .blob(expected) { continue }
            rows.append(KeychainRow(rowID: rowID, identifier: identifier, table: table, values: values))
            if let limit, rows.count >= max(1, limit) { break }
        }
        return rows
    }

    /// Whether an item with the same identity exists: the primary attributes but the access
    /// group, where a missing attribute only equals a missing one.
    private static func existingIdentity(_ database: OpaquePointer, table: KeychainSchema.Table,
                                         attributes: [String: Any], excluding: String? = nil) throws(MulgChainError) -> Bool {
        let columns = table.primaries.filter { !KeychainSchema.unmatchedPrimaries.contains($0) }
        let conditions = columns.map { "CAST(\(quoted($0)) AS BLOB) IS CAST(? AS BLOB)" }.joined(separator: " AND ")
        let sql = "SELECT 1 FROM \(quoted(table.name)) WHERE \(conditions)" + (excluding == nil ? "" : " AND _mulg_ref != ?") + " LIMIT 1"
        var bindings = columns.map { SQLValue.from(attributes[$0]) }
        if let excluding { bindings.append(.text(excluding)) }
        let statement = try prepare(database, sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    // MARK: SQLite plumbing

    private func protectedValue(_ value: Any?, column: String, attributes: [String: Any] = [:], itemClass: String? = nil) throws(MulgChainError) -> SQLValue {
        var stored = SQLValue.from(value)
        let type = itemClass ?? attributes[KeychainKey.itemClass] as? String
        if column == KeychainKey.valueData, [kSecClassGenericPassword as String, kSecClassInternetPassword as String].contains(type ?? ""),
           let policy = attributes[kSecAttrAccessible as String] as? String {
            guard let passwordProtection else { throw .native(errSecUnimplemented) }
            stored = try passwordProtection.seal(stored, accessibility: policy)
        }
        guard [KeychainKey.valueData, KeychainKey.valuePersistentRef].contains(column) else { return stored }
        guard let encryptionKey else { throw .unavailable("credential encryption key missing") }
        return try CredentialProtection.seal(stored, key: encryptionKey)
    }

    private func withConnection<T>(_ body: (OpaquePointer) throws(MulgChainError) -> T) throws(MulgChainError) -> T {
        lock.lock()
        defer { lock.unlock() }
        let database = try openIfNeeded()
        try reconcileNativeMutations(database)
        return try body(database)
    }

    private func openIfNeeded() throws(MulgChainError) -> OpaquePointer {
        if let connection {
            return connection
        }
        _ = try Self.allowsNewEncryptionKey(databaseURL: databaseURL)
        do {
            // Only a folder this store creates gets its permissions set: the shared MulgChain folder belongs to
            // Mulg, and a game's sandbox may not change it (it may only use its own database there).
            let folder = databaseURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
        } catch {
            throw .unavailable(error.localizedDescription)
        }
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            let reason = database.map(Self.message) ?? "cannot open \(databaseURL.lastPathComponent)"
            sqlite3_close_v2(database)
            throw .unavailable(reason)
        }
        sqlite3_busy_timeout(database, 2_000)
        do throws(MulgChainError) {
            do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path) }
            catch { throw .unavailable("could not restrict credential database permissions") }
            guard encryptionKey != nil else { throw .unavailable("macOS credential protection key missing") }
            guard try Self.schema(database) <= Self.schemaVersion else { throw .unavailable("credential database belongs to a newer runtime") }
            try Self.execute(database, "PRAGMA secure_delete = ON")
            try Self.createTables(database)
            try migrateSecrets(database)
        } catch {
            sqlite3_close_v2(database)
            throw error
        }
        connection = database
        return database
    }

    static func createTables(_ database: OpaquePointer) throws(MulgChainError) {
        try execute(database, "CREATE TABLE IF NOT EXISTS _mulg_native_mutations (payload BLOB NOT NULL)")
        for table in KeychainSchema.tables.values.sorted(by: { $0.name < $1.name }) {
            let columns = table.columns.map { "\(quoted($0)) TEXT" }.joined(separator: ", ")
            let key = table.primaries.map(quoted).joined(separator: ", ")
            try execute(database, "CREATE TABLE IF NOT EXISTS \(quoted(table.name)) (\(columns), PRIMARY KEY (\(key)))")
        }
    }

    private func migrateSecrets(_ database: OpaquePointer) throws(MulgChainError) {
        var migrated = false
        try Self.transaction(database) { () throws(MulgChainError) in
            let current = try Self.schema(database)
            guard current <= Self.schemaVersion else { throw .unavailable("credential database belongs to a newer runtime") }
            if current == Self.schemaVersion {
                // Authenticate existing rows before this connection can write with its supplied key.
                for table in KeychainSchema.tables.values {
                    _ = try Self.select(database, table: table, query: [:], limit: nil, key: encryptionKey, unwrapPasswords: false)
                }
                return
            }
            for table in KeychainSchema.tables.values {
                let rows = try Self.select(database, table: table, query: [:], limit: nil, key: encryptionKey, unwrapPasswords: false,
                                           allowPlaintext: current < 2, legacyLayout: current < 3)
                for row in rows where current < 2 {
                    for column in [KeychainKey.valueData, KeychainKey.valuePersistentRef] where row.values[column] != nil {
                        let value = try protectedValue(row.values[column], column: column)
                        try Self.execute(database, "UPDATE \(Self.quoted(table.name)) SET \(Self.quoted(column)) = ? WHERE rowid = ?",
                                         bindings: [value, .text(String(row.rowID))])
                    }
                }
                if current < 3 {
                    try Self.execute(database, "ALTER TABLE \(Self.quoted(table.name)) ADD COLUMN _mulg_ref TEXT")
                    try Self.execute(database, "UPDATE \(Self.quoted(table.name)) SET _mulg_ref = lower(hex(randomblob(16)))")
                    try Self.execute(database, "CREATE UNIQUE INDEX \(Self.quoted("mulg_refs_" + table.name)) ON \(Self.quoted(table.name)) (_mulg_ref)")
                }
            }
            if current < 3 {
                try Self.execute(database, "CREATE TABLE IF NOT EXISTS _mulg_legacy_refs (item_class TEXT, legacy_rowid INTEGER, reference TEXT, PRIMARY KEY (item_class, legacy_rowid))")
                for table in KeychainSchema.tables.values {
                    try Self.execute(database, "INSERT INTO _mulg_legacy_refs SELECT ?, rowid, _mulg_ref FROM \(Self.quoted(table.name))",
                                     bindings: [.text(table.name)])
                }
            }
            try Self.execute(database, "PRAGMA user_version = \(Self.schemaVersion)")
            migrated = true
        }
        if migrated { try Self.execute(database, "VACUUM") }
    }

    private static func transaction<T>(_ database: OpaquePointer, _ body: () throws(MulgChainError) -> T) throws(MulgChainError) -> T {
        try execute(database, "BEGIN IMMEDIATE")
        do throws(MulgChainError) {
            let result = try body()
            try execute(database, "COMMIT")
            return result
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func execute(_ database: OpaquePointer, _ sql: String, bindings: [SQLValue] = []) throws(MulgChainError) {
        let statement = try prepare(database, sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        switch step {
        case SQLITE_DONE, SQLITE_ROW:
            return
        case SQLITE_CONSTRAINT:
            throw .duplicate
        default:
            throw .sqlite(message(database))
        }
    }

    private static func prepare(_ database: OpaquePointer, _ sql: String, bindings: [SQLValue]) throws(MulgChainError) -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw .sqlite(message(database))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = sqlite3_bind_text(statement, index, text, -1, transient)
            case .blob(let data):
                // Empty data has no base address, and a NULL pointer would bind NULL, not an
                // empty value: the item's data would then read back as missing.
                result = data.isEmpty ? sqlite3_bind_zeroblob(statement, index, 0) : data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
                }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw .sqlite(message(database))
            }
        }
        return statement
    }

    private static func column(_ statement: OpaquePointer, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard let bytes = sqlite3_column_blob(statement, index), count > 0 else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        case SQLITE_NULL:
            return .null
        default:
            // TEXT, and numbers a foreign writer stored without the TEXT affinity.
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: text))
        }
    }

    static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func message(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }
}

/// Persistent references MulgChain hands out: "mulg-chain:<table>:<rowid>" as data.
enum PersistentReference {
    enum Identity { case stable(String), legacy(Int64) }
    static func make(table: String, identifier: String) -> Data {
        Data("mulg-chain-v3:\(table):\(identifier)".utf8)
    }
    static func identity(from value: Any?, table: String) -> Identity? {
        guard let data = value as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
        let prefix = "mulg-chain-v3:\(table):"
        if text.hasPrefix(prefix) {
            let identifier = String(text.dropFirst(prefix.count))
            guard identifier.utf8.count == 32, identifier.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            return .stable(identifier)
        }
        return rowID(from: value, table: table).map(Identity.legacy)
    }
    static let prefix = "mulg-chain:"

    static func make(table: String, rowID: Int64) -> Data {
        Data("\(prefix)\(table):\(rowID)".utf8)
    }

    /// The row a reference names. Games may hold references handed out under an earlier product name, so
    /// any `mulg-<letters>:<table>:<row>` prefix resolves, not just the current one. Stable v3
    /// identifiers (`mulg-chain-v3:`, which has a digit and a dash) are a different format and never match.
    static func rowID(from value: Any?, table: String) -> Int64? {
        guard let data = value as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].hasPrefix("mulg-"), parts[0].dropFirst("mulg-".count).allSatisfy(\.isLetter),
              parts[1] == table else { return nil }
        return Int64(parts[2])
    }
}
