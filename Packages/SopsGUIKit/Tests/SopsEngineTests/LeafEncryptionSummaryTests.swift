import Foundation
import Testing

@testable import SopsEngine

/// Ticket #5, claim 1. `SopsBridge.inspectLeafEncryption(in:)` is the Swift
/// side of the bridge call `ProjectHealthCheck` uses to tell a genuinely
/// encrypted file apart from one that only *looks* encrypted — see
/// `gobridge.LeafEncryptionSummary`'s doc comment for the full account and
/// `Engine/gobridge/leafencryption_test.go` for the same reproduction
/// against the real sops CLI, at the Go layer.
@Suite("SopsBridge.inspectLeafEncryption")
struct LeafEncryptionSummaryTests {

    @Test("a fully encrypted document reports every leaf as encrypted")
    func fullyEncryptedDocument() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(plainYAML, format: .yaml, recipients: [key.public])

        let summary = try SopsBridge.inspectLeafEncryption(in: encrypted, format: .yaml)

        // plainYAML: db.host, db.password, api_key — three leaves.
        #expect(summary.leafCount == 3)
        #expect(summary.encryptedLeafCount == 3)
        #expect(!summary.narrowingDeclared)
        #expect(!summary.uncompilableRuleDeclared)
    }

    /// Measured, not assumed: a file encrypted with no rule at all still
    /// carries `unencrypted_suffix: _unencrypted` in its own metadata —
    /// sops's own compiled-in fallback, not a declared choice. This must
    /// not read as `narrowingDeclared`, or the health check that consumes
    /// this field would skip nearly every encrypted file it ever sees.
    @Test("the default suffix sops always writes is not reported as narrowing")
    func defaultSuffixIsNotNarrowing() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(plainYAML, format: .yaml, recipients: [key.public])

        #expect(encrypted.contains("unencrypted_suffix: _unencrypted"),
                "this test's premise depends on sops still writing the default suffix line")
        #expect(!(try SopsBridge.inspectLeafEncryption(in: encrypted, format: .yaml).narrowingDeclared))
    }

    /// The real bug, reproduced against the real `sops` binary rather than
    /// a hand-written fixture: `(unclosed` is a genuinely invalid regular
    /// expression. sops 3.13.3 discards the compile error and writes every
    /// value in cleartext behind a complete, valid metadata block — this is
    /// exactly the file this app's own health check has to be able to tell
    /// apart from a real one, and it never goes through this app's own save
    /// path (which does refuse this — see `refuseUnusableEncryptionRule`).
    @Test("a file the CLI produced with an uncompilable encrypted_regex reports zero encrypted leaves")
    func cliProducedBrokenEncryptedRegex() throws {
        let key = try AgeKeyPair.generate()
        let file = try TempFile(named: "secrets.yaml", contents: plainYAML)

        let encrypted = try SopsCLI.run(
            ["--encrypt", "--age", key.public, "--encrypted-regex", "(unclosed", file.path],
            identity: key)

        // Ground truth: the CLI really did leave every value in cleartext.
        #expect(encrypted.contains("hunter2"))
        #expect(encrypted.contains("sk-live-abc123"))
        #expect(encrypted.contains("encrypted_regex: (unclosed"))

        let summary = try SopsBridge.inspectLeafEncryption(in: encrypted, format: .yaml)

        #expect(summary.leafCount == 3)
        #expect(summary.encryptedLeafCount == 0)
        #expect(summary.narrowingDeclared)
        #expect(summary.uncompilableRuleDeclared)
    }

    @Test("a document with nothing to encrypt reports zero leaves, not zero-of-something")
    func emptyDocument() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt("{}\n", format: .yaml, recipients: [key.public])

        let summary = try SopsBridge.inspectLeafEncryption(in: encrypted, format: .yaml)

        #expect(summary.leafCount == 0)
        #expect(summary.encryptedLeafCount == 0)
    }

    @Test("reading needs no age identity at all")
    func needsNoIdentity() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(plainYAML, format: .yaml, recipients: [key.public])

        // No identity imported or referenced anywhere in this call.
        #expect(try SopsBridge.inspectLeafEncryption(in: encrypted, format: .yaml).leafCount == 3)
    }

    @Test("a document with no sops metadata is refused, not silently reported as encrypted")
    func refusesNonSopsDocument() {
        #expect(throws: SopsBridgeError.self) {
            try SopsBridge.inspectLeafEncryption(in: plainYAML, format: .yaml)
        }
    }
}
