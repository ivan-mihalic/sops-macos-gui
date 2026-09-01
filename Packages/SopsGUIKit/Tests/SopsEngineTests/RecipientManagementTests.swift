import Testing

@testable import SopsEngine

@Suite("SopsBridge recipient management")
struct RecipientManagementTests {
    @Test("metadata and rewrap use the explicit native age recipient list")
    func readsAndRewrapsRecipients() throws {
        let owner = try AgeKeyPair.generate()
        let kept = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let removed = try AgeKeyPair.generate()

        let encrypted = try SopsBridge.encrypt(
            plainYAML, format: .yaml, recipients: [owner.public, removed.public])
        #expect(try SopsBridge.recipients(in: encrypted, format: .yaml) == [owner.public, removed.public])

        let rewrapped = try SopsBridge.updateRecipients(
            encrypted, format: .yaml, to: [kept.public, added.public], agePrivateKey: owner.private)
        #expect(try SopsBridge.recipients(in: rewrapped, format: .yaml) == [kept.public, added.public])
        #expect(try SopsBridge.decrypt(rewrapped, format: .yaml, agePrivateKey: kept.private) == plainYAML)
        #expect(try SopsBridge.decrypt(rewrapped, format: .yaml, agePrivateKey: added.private) == plainYAML)
        #expect(throws: SopsBridgeError.self) {
            try SopsBridge.decrypt(rewrapped, format: .yaml, agePrivateKey: removed.private)
        }
    }
}
