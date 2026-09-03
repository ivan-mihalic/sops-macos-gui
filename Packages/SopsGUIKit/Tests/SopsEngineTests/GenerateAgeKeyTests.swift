import Testing

@testable import SopsEngine

/// SOPS-44: the Access page can mint a key rather than sending the user to a
/// terminal. This is the only call in the app that produces key material, so
/// what it produces has to be provably usable — a pair that looks right but
/// does not belong together would be discovered by the person who lost access
/// to a file, weeks later.
@Suite("SopsBridge age key generation")
struct GenerateAgeKeyTests {
    @Test("the generated pair is a real, matching age identity")
    func producesAMatchingPair() throws {
        let key = try SopsBridge.generateAgeKey()

        #expect(key.privateKey.hasPrefix("AGE-SECRET-KEY-1"))
        #expect(key.publicKey.hasPrefix("age1"))
        // The proof the two halves belong together: the app's own derivation,
        // the same one read-only detection depends on.
        #expect(try SopsBridge.agePublicKey(forPrivateKey: key.privateKey) == key.publicKey)
    }

    @Test("two calls never return the same key")
    func isNotAConstant() throws {
        let first = try SopsBridge.generateAgeKey()
        let second = try SopsBridge.generateAgeKey()
        #expect(first.privateKey != second.privateKey)
        #expect(first.publicKey != second.publicKey)
    }

    @Test("a generated public key is accepted as a recipient")
    func isUsableAsARecipient() throws {
        let key = try SopsBridge.generateAgeKey()
        let document = try SopsBridge.encrypt("value: hello\n", format: .yaml, recipients: [key.publicKey])
        #expect(try SopsBridge.decrypt(document, format: .yaml, agePrivateKey: key.privateKey).contains("hello"))
    }
}
