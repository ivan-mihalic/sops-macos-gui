import Testing

@testable import SopsEngine

/// SOPS-38 phase F3: `SopsBridge.agePublicKey(forPrivateKey:)` is what lets a
/// session's own age public key be derived from the identity `SessionKeyStore`
/// holds, so read-only ciphertext can be detected by comparing public keys
/// against a file's recipients — never by decrypting.
@Suite("SopsBridge age public key derivation")
struct AgePublicKeyTests {
    @Test("derives the same public key age-keygen printed for this identity")
    func matchesTheRealKeyPair() throws {
        let pair = try AgeKeyPair.generate()
        #expect(try SopsBridge.agePublicKey(forPrivateKey: pair.private) == pair.public)
    }

    @Test("two distinct identities derive two distinct public keys")
    func differsBetweenIdentities() throws {
        let a = try AgeKeyPair.generate()
        let b = try AgeKeyPair.generate()
        #expect(try SopsBridge.agePublicKey(forPrivateKey: a.private) != SopsBridge.agePublicKey(forPrivateKey: b.private))
    }

    @Test("a string that is not a valid age identity is refused, not echoed")
    func refusesGarbage() throws {
        #expect(throws: SopsBridgeError.self) {
            try SopsBridge.agePublicKey(forPrivateKey: "hunter2")
        }
    }
}
