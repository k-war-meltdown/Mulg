#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
@testable import MulgVault
import Testing

@Suite("MulgVault cipher")
struct VaultCipherTests {
    // Few rounds keep the tests fast; the format records the count, so opening needs no parameter.
    private let rounds: UInt32 = 10_000

    @Test("A locked database opens again with its password only")
    func roundTrip() throws {
        let plain = Data("SQLite format 3\0 and the rest".utf8)
        let sealed = try VaultCipher.seal(plain, password: "correct horse", rounds: rounds)
        #expect(VaultCipher.isSealed(sealed))
        #expect(!sealed.contains(Data("SQLite".utf8)))
        #expect(try VaultCipher.open(sealed, password: "correct horse") == plain)
        #expect(throws: VaultCipher.Failure.wrongPasswordOrDamaged) { try VaultCipher.open(sealed, password: "wrong") }
    }

    @Test("Each seal uses a new salt; damage is detected, never decrypted to noise")
    func saltAndIntegrity() throws {
        let a = try VaultCipher.seal(Data(), password: "p", rounds: rounds)
        let b = try VaultCipher.seal(Data(), password: "p", rounds: rounds)
        #expect(a != b)
        #expect(try VaultCipher.open(a, password: "p").isEmpty)
        var damaged = a
        damaged[damaged.count - 1] ^= 0x01
        #expect(throws: VaultCipher.Failure.wrongPasswordOrDamaged) { try VaultCipher.open(damaged, password: "p") }
    }

    @Test("Older openssl files are recognised as such, and a hostile round count is refused")
    func formats() throws {
        #expect(!VaultCipher.isSealed(Data("Salted__12345678".utf8) + Data(count: 64)))
        var sealed = try VaultCipher.seal(Data("x".utf8), password: "p", rounds: rounds)
        let start = VaultCipher.magic.count
        sealed.replaceSubrange(start..<start + 4, with: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: VaultCipher.Failure.wrongPasswordOrDamaged) { try VaultCipher.open(sealed, password: "p") }
    }
}
#endif
