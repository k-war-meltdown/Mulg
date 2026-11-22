//
//  MulgVault.swift
//  Mulg
//
//  Created by Venti on 31/01/2023.
//

import Foundation
import CryptoKit
import SwiftUI
import Security
import MulgContracts
import MulgLibrary
import MulgVault

struct MulgVault {
    nonisolated(unsafe) static var shared = MulgVault()
    static var mulgChainPath: URL {
        let mulgChainDir = GameRuntime.mulgContainer.appendingPathComponent("MulgChain")

        if !FileManager.default.fileExists(atPath: mulgChainDir.path) {
            do {
                try FileManager.default.createDirectory(at: mulgChainDir, withIntermediateDirectories: true)
            } catch {
                Log.shared.error(error)
            }
        }

        return mulgChainDir
    }

    // This is only exposed at runtime
    var mulgVaultPlainTextKey: String? = MulgVaultPreferences.shared.mulgVaultEnabled == .selfGeneratedPassword
    ? MulgVaultPassword.shared.getMulgVaultPassword() : nil

    func isMulgVaultEnabled() -> Bool {
        return MulgVaultPreferences.shared.mulgVaultEnabled != .disabled
    }

    func listKeychains() -> [MulgVaultKey] {
        // Enumerate all the keychains
        let keychains = try? FileManager.default
            .contentsOfDirectory(at: MulgVault.mulgChainPath,
                                 includingPropertiesForKeys: nil,
                                 options: .skipsHiddenFiles)
        var keychainList: [MulgVaultKey] = []
        for keychain in keychains ?? [] {
            guard ["db", MulgVaultKey.encryptedKeyExtension].contains(keychain.pathExtension) else { continue }
            let keychainName = keychain.deletingPathExtension().lastPathComponent
            let keychain = MulgVaultKey(appBundleID: keychainName)
            keychainList.append(keychain)
        }
        return keychainList
    }

    func unlockedCount() -> Int {
        var count = 0
        for keychain in listKeychains() where !keychain.chainEncryptionStatus {
            count += 1
        }
        return count
    }

    func unlockChain(_ keychain: MulgVaultKey, sessionLease: GameSessionLease? = nil) async throws {
        if mulgVaultPlainTextKey == nil {
            let task = Task {@MainActor in
                MulgVaultObservable.shared.isMulgVaultUnlockingPromptShown = true
            }
            await task.value
            while MulgVaultObservable.shared.isMulgVaultUnlockingPromptShown {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        if keychain.chainEncryptionStatus {
            try keychain.decryptKeyDB(sessionLease: sessionLease)
        }
    }

    func lockChain(_ keychain: MulgVaultKey, sessionLease: GameSessionLease? = nil) throws {
        if mulgVaultPlainTextKey == nil {
            return
        }
        if !keychain.chainEncryptionStatus {
            try keychain.encryptKeyDB(sessionLease: sessionLease)
        }
    }

    func lockAllChainsAsync() {
        Task {
            for keychain in MulgVault.shared.listKeychains() where !keychain.chainEncryptionStatus {
                try? keychain.encryptKeyDB()
            }
        }
    }
}

class MulgVaultObservable: ObservableObject, @unchecked Sendable {
    static let shared = MulgVaultObservable()

    @Published var mulgVaultEnabled = MulgVault.shared.isMulgVaultEnabled()
    @Published var unlockedCount = MulgVault.shared.unlockedCount()
    @Published var keychains = MulgVault.shared.listKeychains()

    @Published var isMulgVaultUnlockingPromptShown = MulgVaultPreferences.shared.mulgVaultEnabled == .selfGeneratedPassword
    ? false : MulgVaultPreferences.shared.mulgVaultEnabled == .disabled
    ? false : MulgVaultPreferences.shared.promptForMulgVaultPasswordAtLaunch

    func update() {
        mulgVaultEnabled = MulgVault.shared.isMulgVaultEnabled()
        unlockedCount = MulgVault.shared.unlockedCount()
        keychains = MulgVault.shared.listKeychains()
    }
}

struct MulgVaultKey {
    static let encryptedKeyExtension = ContainerPaths.legacyVaultExtension

    var appBundleID: String

    var decryptedKeyDB: URL {
        MulgVault.mulgChainPath
            .appendingPathComponent(appBundleID)
            .appendingPathExtension("db")
    }
    var encryptedKeyDB: URL {
        MulgVault.mulgChainPath
            .appendingPathComponent(appBundleID)
            .appendingPathExtension(MulgVaultKey.encryptedKeyExtension)
    }

    var chainEncryptionStatus: Bool {
        return FileManager.default.fileExists(atPath: encryptedKeyDB.path)
    }

    func encryptKeyDB(sessionLease: GameSessionLease? = nil) throws {
        let lease = try sessionLease ?? GameSessionLease(bundleIdentifier: appBundleID)
        defer { withExtendedLifetime(lease) {} }
        guard !VaultPasswordRotation.hasPending(in: MulgVault.mulgChainPath) else { throw RotationPending() }
        guard !GameWatcher.isRunning(appBundleID) else { throw GameSessionLease.Failure.busy }
        if let plainTextKey = MulgVault.shared.mulgVaultPlainTextKey {
            do {
                try Self.encrypt(decryptedKeyDB, to: encryptedKeyDB, password: plainTextKey)
            } catch {
                try? deleteEncryptedKeyDB()
                throw error
            }

            // The plain database goes only once the encrypted copy exists.
            try deleteKeyDB()

            Task { @MainActor in
                MulgVaultObservable.shared.update()
            }
        }
    }

    func decryptKeyDB(sessionLease: GameSessionLease? = nil) throws {
        let lease = try sessionLease ?? GameSessionLease(bundleIdentifier: appBundleID)
        defer { withExtendedLifetime(lease) {} }
        guard !VaultPasswordRotation.hasPending(in: MulgVault.mulgChainPath) else { throw RotationPending() }
        guard !GameWatcher.isRunning(appBundleID) else { throw GameSessionLease.Failure.busy }
        if let plainTextKey = MulgVault.shared.mulgVaultPlainTextKey {
            do {
                try Self.decrypt(encryptedKeyDB, to: decryptedKeyDB, password: plainTextKey)
                guard Self.isDatabase(decryptedKeyDB, decryptedFrom: encryptedKeyDB) else { throw CryptoFailed() }
            } catch {
                // A wrong password leaves a half-written file; the encrypted copy stays.
                try? deleteKeyDB()
                throw error
            }
            try FileManager.default.removeItem(at: encryptedKeyDB)

            Task { @MainActor in
                MulgVaultObservable.shared.update()
            }
        }
    }

    struct CryptoFailed: LocalizedError {
        var errorDescription: String? {
            "openssl could not encrypt or decrypt the MulgChain keychain. Check the MulgVault password."
        }
    }

    struct RotationPending: LocalizedError {
        var errorDescription: String? { "MulgVault password rotation must finish before this keychain can be changed." }
    }

    /// Encrypts in MulgVault's own format (VaultCipher: PBKDF2 and AES-GCM). Owner-only from the start.
    static func encrypt(_ source: URL, to target: URL, password: String) throws {
        let sealed: Data
        do { sealed = try VaultCipher.seal(Data(contentsOf: source), password: password) } catch { throw CryptoFailed() }
        try writeOwnerOnly(sealed, to: target)
    }

    /// Decrypts either format: MulgVault's own, or the `openssl enc` files older Mulg versions wrote.
    static func decrypt(_ source: URL, to target: URL, password: String) throws {
        let data = try Data(contentsOf: source)
        guard VaultCipher.isSealed(data) else {
            try openssl(["-d", "-in", source.path, "-out", target.path], password: password)
            return
        }
        let plain: Data
        do { plain = try VaultCipher.open(data, password: password) } catch { throw CryptoFailed() }
        try writeOwnerOnly(plain, to: target)
    }

    private static func writeOwnerOnly(_ data: Data, to file: URL) throws {
        try? FileManager.default.removeItem(at: file)
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CryptoFailed()
        }
    }

    /// Runs `openssl enc` with the password on stdin, so it never shows in the process list. Only to
    /// decrypt files an older Mulg wrote; new files use VaultCipher.
    static func openssl(_ arguments: [String], password: String) throws {
        if let output = arguments.firstIndex(of: "-out"), arguments.indices.contains(output + 1) {
            let file = arguments[output + 1]
            if !FileManager.default.fileExists(atPath: file) {
                guard FileManager.default.createFile(atPath: file, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CryptoFailed() }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        task.arguments = ["enc", "-aes-256-cbc", "-pass", "stdin"] + arguments
        let input = Pipe()
        task.standardInput = input
        try task.run()
        // openssl may exit before reading (bad input): fail with EPIPE instead of SIGPIPE killing Mulg.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try input.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8)) } catch {
            task.waitUntilExit()
            throw CryptoFailed()
        }
        try input.fileHandleForWriting.close()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw CryptoFailed() }
    }

    /// `openssl enc` has no integrity check: a wrong password passes its padding check about once in
    /// 256 tries and "decrypts" to noise. The encrypted copy may only go once the result is a SQLite
    /// database (or the empty file an empty database encrypts to: salt header plus one block).
    static func isDatabase(_ plain: URL, decryptedFrom encrypted: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: plain) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 16)) ?? Data()
        // VaultCipher authenticates what it opens: any result, empty included, is the original file.
        if let sealed = try? FileHandle(forReadingFrom: encrypted), let start = try? sealed.read(upToCount: 64),
           VaultCipher.isSealed(start) {
            try? sealed.close()
            return header.isEmpty || header == Data("SQLite format 3\0".utf8)
        }
        if header.isEmpty {
            let size = (try? FileManager.default.attributesOfItem(atPath: encrypted.path)[.size] as? NSNumber)?.intValue ?? .max
            return size <= 32
        }
        return header == Data("SQLite format 3\0".utf8)
    }

    func deleteKeyDB() throws {
        try FileManager.default.removeItem(at: decryptedKeyDB)
    }

    func deleteEncryptedKeyDB() throws {
        try FileManager.default.removeItem(at: encryptedKeyDB)
    }
}

class MulgVaultPassword: @unchecked Sendable {
    static let shared = MulgVaultPassword()

    let tag = "io.mulg.masterkey"

    private func leases(for chains: [MulgVaultKey]) throws -> [String: GameSessionLease] {
        var result: [String: GameSessionLease] = [:]
        for chain in chains {
            if result[chain.appBundleID] != nil { continue }
            guard !GameWatcher.isRunning(chain.appBundleID) else { throw GameSessionLease.Failure.busy }
            result[chain.appBundleID] = try GameSessionLease(bundleIdentifier: chain.appBundleID)
        }
        return result
    }

    func setMulgVaultPassword(_ key: String) throws {
        let rotation = try GameSessionLease(bundleIdentifier: "io.mulg.vault-rotation")
        defer { withExtendedLifetime(rotation) {} }
        let chains = MulgVault.shared.listKeychains()
        let sessionLeases = try leases(for: chains)
        defer { withExtendedLifetime(sessionLeases) {} }
        try finishRotation()
        let oldKey = getMulgVaultPassword()
        try storePassword(key, service: tag + ".pending")
        do {
            try VaultPasswordRotation.prepare(in: MulgVault.mulgChainPath, identifiers: sessionLeases.keys.sorted()) { id, target in
                let chain = MulgVaultKey(appBundleID: id)
                let plain = target.appendingPathExtension("plain")
                let verified = target.appendingPathExtension("verified")
                defer { try? FileManager.default.removeItem(at: plain); try? FileManager.default.removeItem(at: verified) }
                let source: URL
                if chain.chainEncryptionStatus {
                    guard let oldKey else { throw CryptoStatus(status: errSecAuthFailed) }
                    try MulgVaultKey.decrypt(chain.encryptedKeyDB, to: plain, password: oldKey)
                    guard MulgVaultKey.isDatabase(plain, decryptedFrom: chain.encryptedKeyDB) else { throw MulgVaultKey.CryptoFailed() }
                    source = plain
                } else { source = chain.decryptedKeyDB }
                try MulgVaultKey.encrypt(source, to: target, password: key)
                try MulgVaultKey.decrypt(target, to: verified, password: key)
                guard try Data(contentsOf: source) == Data(contentsOf: verified) else { throw MulgVaultKey.CryptoFailed() }
            }
            try finishRotation()
        } catch {
            if !VaultPasswordRotation.hasPending(in: MulgVault.mulgChainPath) { try? deletePassword(service: tag + ".pending") }
            throw error
        }
    }

    struct CryptoStatus: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "MulgVault Keychain operation failed (\(status)). Existing rotation data was retained." }
    }

    // The vault password lives in Mulg's own sealed file (SealedSecret, opened by this Mac's Secure Enclave),
    // never in the macOS Keychain (2026-10-10). An item an older Mulg stored there is moved into the file the
    // first time it is read, then deleted; Mulg created it, so macOS asks nothing.

    private static var secretsFolder: URL {
        GameRuntime.mulgContainer.appendingPathComponent("Mulg", isDirectory: true).appendingPathComponent("Vault", isDirectory: true)
    }

    private func secretFile(_ service: String) -> URL {
        Self.secretsFolder.appendingPathComponent(service + ".sealed", isDirectory: false)
    }

    private func storePassword(_ key: String, service: String) throws {
        do { try SealedSecret.write(Data(key.utf8), to: secretFile(service), purpose: "vault/" + service) }
        catch { throw CryptoStatus(status: errSecIO) }
        LegacyKeychainItem.delete(service: service)
    }

    private func deletePassword(service: String) throws {
        let file = secretFile(service)
        if FileManager.default.fileExists(atPath: file.path) {
            do { try FileManager.default.removeItem(at: file) } catch { throw CryptoStatus(status: errSecIO) }
        }
        LegacyKeychainItem.delete(service: service)
    }

    private func finishRotation() throws {
        guard VaultPasswordRotation.hasPending(in: MulgVault.mulgChainPath) else { return }
        guard let pending = getPassword(service: tag + ".pending") else { throw CryptoStatus(status: errSecItemNotFound) }
        try VaultPasswordRotation.recover(in: MulgVault.mulgChainPath) {
            try storePassword(pending, service: tag)
            MulgVault.shared.mulgVaultPlainTextKey = pending
        }
        try deletePassword(service: tag + ".pending")
        Task { @MainActor in MulgVaultObservable.shared.update() }
    }

    func recoverRotation() throws {
        guard VaultPasswordRotation.hasPending(in: MulgVault.mulgChainPath) else { return }
        let rotation = try GameSessionLease(bundleIdentifier: "io.mulg.vault-rotation")
        let sessionLeases = try leases(for: MulgVault.shared.listKeychains())
        defer { withExtendedLifetime((rotation, sessionLeases)) {} }
        try finishRotation()
    }

    func getMulgVaultPassword() -> String? {
        getPassword(service: tag)
    }

    private func getPassword(service: String) -> String? {
        let purpose = "vault/" + service
        do {
            if let data = try SealedSecret.read(secretFile(service), purpose: purpose) { return String(data: data, encoding: .utf8) }
        } catch {
            Log.shared.error(error)
            return nil
        }
        // Once: an older Mulg's Keychain item moves into the sealed file and leaves the Keychain.
        guard let legacy = LegacyKeychainItem.read(service: service) else { return nil }
        if (try? SealedSecret.write(legacy, to: secretFile(service), purpose: purpose)) != nil {
            LegacyKeychainItem.delete(service: service)
        }
        return String(data: legacy, encoding: .utf8)
    }

    func removeMulgVaultPassword() {
        do { try recoverRotation() } catch { Log.shared.error(error); return }
        let chains = MulgVault.shared.listKeychains()
        let sessionLeases: [String: GameSessionLease]
        do { sessionLeases = try leases(for: chains) } catch { Log.shared.error(error); return }
        defer { withExtendedLifetime(sessionLeases) {} }
        // Decrypt all key dbs
        for chain in chains where chain.chainEncryptionStatus {
            do { try chain.decryptKeyDB(sessionLease: sessionLeases[chain.appBundleID]) }
            catch { Log.shared.error(error); return }
        }

        // Remove the master key (its sealed file, and any older Keychain item).
        do { try deletePassword(service: tag) } catch { Log.shared.error(error) }

        MulgVaultPreferences.shared.mulgVaultEnabled = .disabled
        MulgVault.shared.mulgVaultPlainTextKey = nil

        Task { @MainActor in
            MulgVaultObservable.shared.update()
        }
    }

    func forceResetMulgVaultPassword() {
        do { try recoverRotation() } catch { Log.shared.error(error); return }
        // If a key is in memory, don't do anything (prevent accidental deletion)
        if MulgVault.shared.mulgVaultPlainTextKey != nil {
            return
        }
        let chains = MulgVault.shared.listKeychains()
        let sessionLeases: [String: GameSessionLease]
        do { sessionLeases = try leases(for: chains) } catch { Log.shared.error(error); return }
        defer { withExtendedLifetime(sessionLeases) {} }
        // Remove the master key (its sealed file, and any older Keychain item).
        do { try deletePassword(service: tag) } catch { Log.shared.error(error) }

        MulgVaultPreferences.shared.mulgVaultEnabled = .disabled
        MulgVault.shared.mulgVaultPlainTextKey = nil

        // Being a force reset, we have to nuke everything (because it's useless otherwise)
        for chain in chains {
            try? chain.deleteEncryptedKeyDB()
        }

        Task { @MainActor in
            MulgVaultObservable.shared.update()
        }
    }

    func validatePassword(_ key: String) -> Bool {
        return key == getMulgVaultPassword()
    }

    func generateVerySecurePassword() -> String {
        // oh my god
        let length = 32
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+"
        return String((0..<length).map { _ in letters.randomElement() ?? "." })
    }
}

/// The macOS Keychain, for migration only: Mulg's vault password used to live there. It is read once to move
/// it into Mulg's sealed file, and deleted; nothing new is ever written to the Keychain.
private enum LegacyKeychainItem {
    static func read(service: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: service, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var value: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess ? value as? Data : nil
    }

    static func delete(service: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: service] as CFDictionary)
    }
}
