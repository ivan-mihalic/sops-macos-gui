import Foundation
import Testing

@testable import SopsEngine

let plainYAML = """
db:
    host: localhost
    password: hunter2
api_key: sk-live-abc123

"""

@Suite("SOPS CLI compatibility, driven from Swift")
struct CompatibilityTests {

    @Test("the sops CLI can decrypt what the in-process bridge encrypted")
    func cliDecryptsBridgeOutput() throws {
        let key = try AgeKeyPair.generate()

        let encrypted = try SopsBridge.encrypt(plainYAML, format: .yaml, recipients: [key.public])
        let file = try TempFile(named: "secrets.yaml", contents: encrypted)

        let decrypted = try SopsCLI.run(["--decrypt", file.path], identity: key)

        #expect(decrypted == plainYAML)
    }

    @Test("the in-process bridge can decrypt what the sops CLI encrypted")
    func bridgeDecryptsCLIOutput() throws {
        let key = try AgeKeyPair.generate()
        let file = try TempFile(named: "secrets.yaml", contents: plainYAML)

        let encrypted = try SopsCLI.run(
            ["--encrypt", "--age", key.public, file.path], identity: key)
        let decrypted = try SopsBridge.decrypt(encrypted, format: .yaml, agePrivateKey: key.private)

        #expect(decrypted == plainYAML)
    }

    @Test("encrypted_regex round-trips through the CLI")
    func encryptedRegexRoundTrip() throws {
        let key = try AgeKeyPair.generate()

        let encrypted = try SopsBridge.encrypt(
            plainYAML, format: .yaml, recipients: [key.public], encryptedRegex: "^(password|api_key)$")

        #expect(encrypted.contains("host: localhost"), "non-matching key must stay readable")
        #expect(!encrypted.contains("hunter2"), "matching key must be encrypted")

        let file = try TempFile(named: "secrets.yaml", contents: encrypted)
        #expect(try SopsCLI.run(["--decrypt", file.path], identity: key) == plainYAML)
    }

    @Test("decrypting with an unrelated identity throws rather than returning garbage")
    func wrongIdentityThrows() throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()

        let encrypted = try SopsBridge.encrypt(plainYAML, format: .yaml, recipients: [owner.public])

        #expect(throws: SopsBridgeError.self) {
            try SopsBridge.decrypt(encrypted, format: .yaml, agePrivateKey: stranger.private)
        }
    }

    @Test("repeated round-trips are stable and do not leak the plaintext into the output")
    func repeatedRoundTripsAreStable() throws {
        let key = try AgeKeyPair.generate()

        for _ in 0..<25 {
            let encrypted = try SopsBridge.encrypt(plainYAML, format: .yaml, recipients: [key.public])
            #expect(!encrypted.contains("hunter2"))
            #expect(try SopsBridge.decrypt(encrypted, format: .yaml, agePrivateKey: key.private) == plainYAML)
        }
    }
}
