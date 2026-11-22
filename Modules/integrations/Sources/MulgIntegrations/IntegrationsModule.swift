import Foundation
import CryptoKit
import MulgContracts
import MulgEngine
import MulgIntegrationsHooks

/// The integrations module inside the game (PLAN.md §1.3). It runs MulgChain, the keychain
/// that lets ad-hoc signed games sign in and keep their login.
///
/// MulgChain has to answer the game's very first keychain call, so it starts in `prepare`.
/// Discord Rich Presence waits for `activate`.
@MainActor
public final class IntegrationsModule: GameModule {
    public let id = ModuleID.integrations

    public private(set) var mulgChain: MulgChain?
    private var authentication: AuthenticationCompatibility?

    public static let keychainHooks = [
        "SecItemCopyMatching", "SecItemAdd", "SecItemUpdate", "SecItemDelete",
        "SecKeyCreateRandomKey", "SecKeyGeneratePair"
    ]

    public init() {}

    public func prepareCore(_ context: ModuleContext) throws -> Bool {
        mulg_authentication_disable()
        // Recovery keeps the game off the real Keychain too: logins last until it quits.
        installSessionChain(context)
        return false
    }

    public func prepare(_ context: ModuleContext) throws {
        self.context = context
        let authentication = AuthenticationCompatibility(context)
        self.authentication = authentication
        authentication.install()
        let settings = context.settings
        guard settings.mulgChain else {
            // "Mulg Keychain" off means "don't save logins", never the real macOS Keychain.
            installSessionChain(context)
            return
        }
        // Prepare must run even with a missing bridge, so enabled storage cannot become native
        // fallback. A later game call schedules one retry on main after credential unlock.
        mulg_keychain_require_backend { [weak self, weak context] in
            MainActor.assumeIsolated {
                guard let self, let context else { return }
                do {
                    try self.installChain(context)
                    context.notices.show(Notice("Saved credentials are available again"))
                } catch { context.logger(for: self.id).error("Credential retry failed: \(String(describing: error), privacy: .public)") }
            }
        }
        // The macOS keychain answers in tens of milliseconds, or first asks to be unlocked, so the
        // game's start does not wait for it: its first keychain call waits instead, if it comes
        // before the store is ready. A failure here leaves the retry above in place.
        let database = context.paths.mulgChainDatabase(for: context.bundleIdentifier)
        let readKey = Self.keyReader(context, paths: context.paths)
        let protection = Self.passwordProtection(context)
        let debugging = context.settings.mulgChainDebugging
        let logger = context.logger(for: id)
        let createKey: Bool
        do { createKey = try MulgChainStore.allowsNewEncryptionKey(databaseURL: database) } catch {
            // A database still locked by the vault (or unreadable): sign-in must work all the same.
            logger.error("Saved logins unavailable: \(String(describing: error), privacy: .public)")
            installSessionChain(context)
            showSessionLoginNotice(context)
            return
        }
        mulg_keychain_begin_loading()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let chain = Self.makeChain(readKey: readKey, database: database, createKey: createKey, debugging: debugging, protection: protection)
            // Never a keychain that refuses everything: with no saved-login store the game could not keep any
            // sign-in token (e-mail, Google or another provider), so the login itself failed and was asked for
            // again and again. A store for this session keeps sign-in working; the login is not remembered.
            let installed = chain ?? Self.makeSessionChain(debugging: debugging, protection: protection)
            mulg_keychain_install(installed, debugging)
            mulg_keychain_end_loading()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if chain == nil {
                        logger.error("Saved logins unavailable: their key could not be read (see the credential key messages); this session keeps logins in memory")
                        if let self, let context = self.context { self.showSessionLoginNotice(context) }
                    }
                    self?.mulgChain = installed
                }
            }
        }
        for name in Self.keychainHooks {
            try? context.hooks.claim(name, owner: id, kind: .interpose)
        }
    }

    private weak var context: ModuleContext?

    /// Sign-in still works; the player learns why the game will ask again next time.
    private func showSessionLoginNotice(_ context: ModuleContext) {
        context.notices.show(Notice("Logins are not saved this time",
            lines: ["You can sign in as usual, but this game will ask again next launch.",
                    "Open the game from Mulg again; if it keeps happening, use Clear saved logins in its Privacy settings."],
            style: .warning, duration: .seconds(8)))
    }

    /// The database key, from any thread: the game's sealed key file (SealedSecret), never the macOS Keychain.
    /// On the one launch that runs without the keychain wall, a key an older Mulg kept there is moved into the
    /// file and deleted (through the bridge, which may use the Keychain API).
    private static func keyReader(_ context: ModuleContext, paths: ContainerPaths) -> @Sendable (String, Bool) -> Data? {
        nonisolated(unsafe) let bridge = context.bridge
        let id = context.bundleIdentifier
        let file = paths.mulgChainKey(for: id), purpose = ContainerPaths.mulgChainKeyPurpose(for: id)
        return { path, create in
            databaseKey(file: file, purpose: purpose, create: create,
                        legacy: { bridge?.credentialEncryptionKey?(forDatabasePath: path, createIfMissing: false) },
                        removeLegacy: { bridge?.removeLegacyCredentialKey?(forDatabasePath: path) })
        }
    }

    /// Any thread. A key file that exists but cannot be opened is never replaced: its database stays as it is.
    nonisolated static func databaseKey(file: URL, purpose: String, create: Bool,
                                        legacy: () -> Data?, removeLegacy: () -> Void) -> Data? {
        do {
            if let key = try SealedSecret.read(file, purpose: purpose) { return key.count == 32 ? key : nil }
        } catch {
            MulgLog.logger(.integrations).error("Credential key file unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
        if let old = legacy(), old.count == 32 {
            // The old item goes only once the file opens again; a failed write keeps it for the next launch.
            do { try SealedSecret.write(old, to: file, purpose: purpose); removeLegacy() }
            catch { MulgLog.logger(.integrations).error("Credential key not moved yet: \(String(describing: error), privacy: .public)") }
            return old
        }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        // A key that could not be kept would lock away everything saved with it.
        do { try SealedSecret.write(key, to: file, purpose: purpose) } catch {
            MulgLog.logger(.integrations).error("Credential key could not be kept: \(String(describing: error), privacy: .public)")
            return nil
        }
        return key
    }

    /// "Don't save logins": a store in the game's own temporary folder with a key that is never written down.
    /// Logins work while the game runs; the next start removes the file.
    private func installSessionChain(_ context: ModuleContext) {
        let chain = Self.makeSessionChain(debugging: context.settings.mulgChainDebugging, protection: Self.passwordProtection(context))
        mulgChain = chain
        mulg_keychain_install(chain, context.settings.mulgChainDebugging)
        for name in Self.keychainHooks {
            try? context.hooks.claim(name, owner: id, kind: .interpose)
        }
    }

    private static func passwordProtection(_ context: ModuleContext) -> PasswordProtection? {
        nonisolated(unsafe) let bridge = context.bridge
        guard bridge?.responds(to: NSSelectorFromString("credentialPasswordEnvelope:accessibility:opening:failure:")) == true else { return nil }
        return PasswordProtection { data, accessibility, opening in
            var failure: NSError?
            let answer = bridge?.credentialPasswordEnvelope?(data, accessibility: accessibility, opening: opening, failure: &failure)
            let code = failure.map { $0.domain == NSOSStatusErrorDomain ? OSStatus(clamping: $0.code) : errSecDecode } ?? errSecDecode
            return (answer == nil ? code : errSecSuccess, answer)
        }
    }

    /// Any thread: a store in the game's own temporary folder with a key that is never written down. Logins
    /// work while the game runs; the next start removes the file (installSessionChain).
    private nonisolated static func makeSessionChain(debugging: Bool, protection: PasswordProtection?) -> MulgChain {
        let folder = FileManager.default.temporaryDirectory, files = FileManager.default
        for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("mulgchain-session-") {
            try? files.removeItem(at: folder.appendingPathComponent(name))
        }
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("mulgchain-session-" + UUID().uuidString + ".db")
        let store = MulgChainStore(databaseURL: database, encryptionKey: SymmetricKey(size: .bits256), passwordProtection: protection)
        return MulgChain(store: store, debugging: debugging)
    }

    /// Any thread: reads (or makes) the database key and opens the store.
    private nonisolated static func makeChain(readKey: @Sendable (String, Bool) -> Data?, database: URL, createKey: Bool,
                                              debugging: Bool, protection: PasswordProtection?) -> MulgChain? {
        guard let key = readKey(database.path, createKey), key.count == 32 else { return nil }
        let store = MulgChainStore(databaseURL: database, encryptionKey: SymmetricKey(data: key), passwordProtection: protection)
        return MulgChain(store: store, debugging: debugging)
    }

    private func installChain(_ context: ModuleContext) throws {
        let database = context.paths.mulgChainDatabase(for: context.bundleIdentifier)
        let createKey = try MulgChainStore.allowsNewEncryptionKey(databaseURL: database)
        guard let chain = Self.makeChain(readKey: Self.keyReader(context, paths: context.paths), database: database, createKey: createKey,
                                         debugging: context.settings.mulgChainDebugging, protection: Self.passwordProtection(context)) else {
            throw MulgChainError.unavailable("the saved-login key could not be read")
        }
        mulgChain = chain
        mulg_keychain_install(chain, context.settings.mulgChainDebugging)
        for name in Self.keychainHooks {
            try? context.hooks.claim(name, owner: id, kind: .interpose)
        }
    }

    public func activate(_ context: ModuleContext) {
        DiscordPresence.start(context.settings.discordActivity, bundleIdentifier: context.bundleIdentifier)
    }
}
