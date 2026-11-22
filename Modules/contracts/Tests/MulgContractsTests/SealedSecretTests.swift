import Foundation
@testable import MulgContracts
import Testing

@Suite("Sealed secrets (no macOS Keychain)", .enabled(if: SealedSecret.isAvailable))
struct SealedSecretTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mulg-sealed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A sealed secret opens again for its purpose only")
    func roundTrip() throws {
        let secret = Data((0..<32).map { UInt8($0) })
        let sealed = try SealedSecret.seal(secret, purpose: "credentials/com.example.game")
        #expect(try SealedSecret.open(sealed, purpose: "credentials/com.example.game") == secret)
        #expect(throws: SealedSecret.Failure.wrongPurpose) { try SealedSecret.open(sealed, purpose: "credentials/com.example.other") }
        #expect(!sealed.contains(secret)) // never stored in the clear
    }

    @Test("A damaged file is refused, a missing one reads as nil")
    func damaged() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("game.key")
        #expect(try SealedSecret.read(file, purpose: "p") == nil)
        try SealedSecret.write(Data("secret".utf8), to: file, purpose: "p")
        #expect(try SealedSecret.read(file, purpose: "p") == Data("secret".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count - 5] ^= 0xFF
        try bytes.write(to: file)
        #expect(throws: (any Error).self) { try SealedSecret.read(file, purpose: "p") }
        #expect(throws: SealedSecret.Failure.damaged) { try SealedSecret.open(Data("not a sealed file".utf8), purpose: "p") }
    }

    @Test("Each game's key file sits beside its database, with its own purpose")
    func paths() {
        let paths = ContainerPaths(home: URL(fileURLWithPath: "/Users/test"))
        #expect(paths.mulgChainKey(for: "com.example.game").lastPathComponent == "com.example.game.key")
        #expect(paths.mulgChainKey(for: "com.example.game").deletingLastPathComponent() == paths.mulgChainDirectory)
        #expect(ContainerPaths.mulgChainKeyPurpose(for: "a") != ContainerPaths.mulgChainKeyPurpose(for: "b"))
    }
}

/// Nothing outside migration and the interposes may call the macOS Keychain (2026-10-10). A new direct call
/// anywhere in Mulg's own code fails this test.
@Suite("No macOS Keychain calls")
struct NoKeychainCallsTests {
    static let allowed: Set<String> = [
        "Host/Mulg/Utils/MulgVault.swift",                                         // migration of the old vault password
        "Modules/bridge/Sources/MulgBridgeAppKit/AppKitBridge.swift",              // migration of old game database keys
        "Host/Mulg/Utils/Entitlements.swift",                                      // whether an old key still waits to move
        "Modules/integrations/Sources/MulgIntegrationsHooks/MulgKeychainHooks.m",  // forwards non-game callers
        "Apps/Probe/main.swift",                                                   // the runtime probe's own checks
    ]

    @Test("Only the migration paths and the interposes name a Keychain call")
    func scan() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pattern = try Regex(#"\b(SecItemAdd|SecItemCopyMatching|SecItemUpdate|SecItemDelete|SecKeychain[A-Za-z]+)\s*\("#)
        var offenders: [String] = [], scanned = 0
        for top in ["Host", "Modules", "Apps", "Tools"] {
            guard let walk = FileManager.default.enumerator(at: repository.appendingPathComponent(top), includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walk where ["swift", "m", "mm", "h", "c"].contains(file.pathExtension) {
                let relative = String(file.path.dropFirst(repository.path.count + 1))
                guard !relative.contains("/Tests/"), !relative.contains("/.build/"), !Self.allowed.contains(relative) else { continue }
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                scanned += 1
                if text.contains(pattern) { offenders.append(relative) }
            }
        }
        #expect(offenders.isEmpty, "Keychain calls in: \(offenders.joined(separator: ", "))")
        // The scan really ran: hundreds of sources, and every allowed file still exists.
        #expect(scanned > 300, "scanned \(scanned)")
        #expect(Self.allowed.allSatisfy { FileManager.default.fileExists(atPath: repository.appendingPathComponent($0).path) })
    }
}
