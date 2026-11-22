import CryptoKit
import Foundation
import Security
import Testing
@testable import MulgIntegrations

@Suite("Protected login credentials")
struct PasswordProtectionTests {
    private let key = SymmetricKey(data: Data(repeating: 9, count: 32))
    private let policy = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    private struct Fixture: Codable { let policy: String; let data: Data }

    // Synthetic boundary adapter: tests storage behavior without accessing real Keychain/SEP.
    private var protection: PasswordProtection { PasswordProtection(operation: fixtureOperation) }
    private func fixtureOperation(_ data: Data, _ policy: String, _ opening: Bool) -> (OSStatus, Data?) {
            do {
                if opening {
                    let fixture = try PropertyListDecoder().decode(Fixture.self, from: data)
                    guard fixture.policy == policy else { return (errSecDecode, nil) }
                    return (errSecSuccess, fixture.data)
                }
                return (errSecSuccess, try PropertyListEncoder().encode(Fixture(policy: policy, data: data)))
            } catch { return (errSecDecode, nil) }
    }
    private func query(_ secret: String? = nil) -> [AnyHashable: Any] {
        var value: [AnyHashable: Any] = [kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: "OAuth", kSecAttrService as String: "fixture-auth"]
        if let secret { value[kSecValueData as String] = Data(secret.utf8); value[kSecAttrAccessible as String] = policy }
        return value
    }
    private func find(_ chain: MulgChain, _ query: [AnyHashable: Any]) -> (OSStatus, AnyObject?) {
        var result: AnyObject?
        return (chain.copyMatching(query, result: &result), result)
    }

    @Test func googleStyleCredentialSurvivesReopenUpdateAndPlaintextQuery() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mulg-protection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("game.db")
        let first = MulgChain(store: MulgChainStore(databaseURL: file, encryptionKey: key, passwordProtection: protection))
        #expect(first.add(query("first-login"), result: nil) == errSecSuccess)
        let reopened = MulgChain(store: MulgChainStore(databaseURL: file, encryptionKey: key, passwordProtection: protection))
        var request = query("first-login")
        request[kSecReturnData as String] = true
        #expect(find(reopened, request).1 as? Data == Data("first-login".utf8))
        #expect(reopened.update(query(), attributes: [kSecValueData as String: Data("refreshed-login".utf8)]) == errSecSuccess)
        request[kSecValueData as String] = Data("refreshed-login".utf8)
        #expect(find(reopened, request).1 as? Data == Data("refreshed-login".utf8))
        #expect(reopened.remove(query()) == errSecSuccess)
        #expect(find(reopened, request).0 == errSecItemNotFound)
    }

    @Test func failedPolicyChangeKeepsExistingCredentialAndPolicy() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mulg-protection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let adapter = PasswordProtection { data, policy, opening in
            if !opening, policy == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String { return (errSecInteractionNotAllowed, nil) }
            return fixtureOperation(data, policy, opening)
        }
        let chain = MulgChain(store: MulgChainStore(databaseURL: folder.appendingPathComponent("game.db"), encryptionKey: key, passwordProtection: adapter))
        #expect(chain.add(query("saved-login"), result: nil) == errSecSuccess)
        #expect(chain.update(query(), attributes: [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) == errSecInteractionNotAllowed)
        var request = query("saved-login")
        request[kSecReturnData as String] = true
        #expect(find(chain, request).1 as? Data == Data("saved-login".utf8))
    }

    /// Older sign-in SDKs save tokens as "always" or "when passcode set". They were refused (errSecUnimplemented),
    /// so the login failed; they are sealed under the nearest native policy at least as strong, and read back as asked.
    @Test(arguments: [("dk", kSecAttrAccessibleAfterFirstUnlock as String),
                      ("dku", kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String),
                      (kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)])
    func olderAccessLevelsAreSealedUnderANativePolicy(requested: String, native: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mulg-protection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        nonisolated(unsafe) var sealedWith: [String] = []
        let adapter = PasswordProtection { data, policy, opening in
            if !opening { sealedWith.append(policy) }
            return fixtureOperation(data, policy, opening)
        }
        let file = folder.appendingPathComponent("game.db")
        let chain = MulgChain(store: MulgChainStore(databaseURL: file, encryptionKey: key, passwordProtection: adapter))
        var item = query("token")
        item[kSecAttrAccessible as String] = requested
        #expect(chain.add(item, result: nil) == errSecSuccess)
        #expect(sealedWith == [native])
        let reopened = MulgChain(store: MulgChainStore(databaseURL: file, encryptionKey: key, passwordProtection: adapter))
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecReturnAttributes as String] = true
        let found = try #require(find(reopened, request).1 as? NSDictionary)
        #expect(found[kSecValueData] as? Data == Data("token".utf8))
        #expect(found[kSecAttrAccessible] as? String == requested)
        #expect(PasswordProtection.nativePolicy(for: "unknown") == nil)
    }

    @Test func nativeUnavailableNeverStoresUnprotectedFallback() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mulg-protection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let adapter = PasswordProtection { _, _, _ in (errSecInteractionNotAllowed, nil) }
        let chain = MulgChain(store: MulgChainStore(databaseURL: folder.appendingPathComponent("game.db"), encryptionKey: key, passwordProtection: adapter))
        #expect(chain.add(query("secret"), result: nil) == errSecInteractionNotAllowed)
        #expect(find(chain, query()).0 == errSecItemNotFound)
        var plain = query("plain-secret")
        plain[kSecAttrAccessible as String] = nil
        #expect(chain.add(plain, result: nil) == errSecSuccess)
    }
}
