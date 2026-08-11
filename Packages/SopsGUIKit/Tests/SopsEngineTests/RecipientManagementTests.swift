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

        let encrypted = try SopsBridge.encryptYAML(
            plainYAML, recipients: [owner.public, removed.public])
        #expect(try SopsBridge.recipients(in: encrypted) == [owner.public, removed.public])

        let rewrapped = try SopsBridge.updateRecipients(
            encrypted, to: [kept.public, added.public], agePrivateKey: owner.private)
        #expect(try SopsBridge.recipients(in: rewrapped) == [kept.public, added.public])
        #expect(try SopsBridge.decryptYAML(rewrapped, agePrivateKey: kept.private) == plainYAML)
        #expect(try SopsBridge.decryptYAML(rewrapped, agePrivateKey: added.private) == plainYAML)
        #expect(throws: SopsBridgeError.self) {
            try SopsBridge.decryptYAML(rewrapped, agePrivateKey: removed.private)
        }
    }
}
