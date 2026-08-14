import Foundation
import ScratchCleanup
import Testing
@testable import SopsHealth

/// Ticket #8, claim 1: `isPlaintextSecretCandidate` used to match only the
/// `.env` family. These pin the widened, name-only-certain set (`keys.txt`,
/// SSH private key names, `.p12`/`.pfx`), and separately the content-checked
/// `.pem`/`.key` handling that exists precisely *because* those two
/// extensions are not name-only-certain — a Let's Encrypt directory puts
/// `cert.pem` and `privkey.pem` side by side, and only one of them is a
/// secret.
///
/// Every negative case here is a file a real project commits on purpose. A
/// false positive from any of them would be exactly the "cries wolf" failure
/// `isPlaintextSecretCandidate`'s own doc comment warns against.
@Suite("Widened plaintext-secret candidate names (ticket #8, claim 1)")
struct PlaintextSecretCandidateNameTests {

    @Test("age-keygen's own default output filename is a candidate", arguments: [
        "keys.txt", "KEYS.TXT", "Keys.txt",
    ])
    func ageKeygenDefaultIsCandidate(name: String) {
        #expect(ProjectScanner.isPlaintextSecretCandidate(name))
    }

    @Test("a file merely containing 'keys' is not a candidate", arguments: [
        "keys.txt.example", "apikeys.txt", "keys.txt.bak", "public-keys.txt",
    ])
    func nearMissesToKeysTxtAreNotCandidates(name: String) {
        #expect(!ProjectScanner.isPlaintextSecretCandidate(name))
    }

    @Test("ssh-keygen's default private key names are candidates", arguments: [
        "id_rsa", "id_dsa", "id_ecdsa", "id_ecdsa_sk", "id_ed25519", "id_ed25519_sk",
    ])
    func sshPrivateKeyNamesAreCandidates(name: String) {
        #expect(ProjectScanner.isPlaintextSecretCandidate(name))
    }

    @Test("the public half of an SSH key pair is never a candidate", arguments: [
        "id_rsa.pub", "id_ed25519.pub", "id_ecdsa_sk.pub",
    ])
    func sshPublicKeysAreNeverCandidates(name: String) {
        #expect(!ProjectScanner.isPlaintextSecretCandidate(name))
    }

    @Test("PKCS12/PFX bundles are candidates by extension alone", arguments: [
        "client.p12", "DeveloperID.p12", "identity.pfx",
    ])
    func pkcs12BundlesAreCandidates(name: String) {
        #expect(ProjectScanner.isPlaintextSecretCandidate(name))
    }

    @Test("an unrelated file that merely mentions 'id_' is not a candidate", arguments: [
        "id_generator.js", "identity.txt", "id_rsa.md",
    ])
    func nearMissesToSSHNamesAreNotCandidates(name: String) {
        #expect(!ProjectScanner.isPlaintextSecretCandidate(name))
    }

    // `.pem`/`.key` are deliberately absent from `isPlaintextSecretCandidate`
    // itself — see `PlaintextPEMContentTests` below for how those two are
    // decided, and why name alone is not enough for them.
    @Test("bare .pem/.key extensions are not name-only candidates", arguments: [
        "cert.pem", "server.key", "anything.pem",
    ])
    func pemAndKeyAreNotNameOnlyCandidates(name: String) {
        #expect(!ProjectScanner.isPlaintextSecretCandidate(name))
    }
}

/// The content-based half: `.pem`/`.key` files are candidates only when their
/// content looks like a private key, never by extension alone. Exercised
/// through the real scan pipeline (`ProjectScanner.scan`), not the helper
/// function directly, because the point being proven is that a whole file on
/// disk — real `openssl`-produced key and certificate material, not a
/// hand-typed approximation of what PEM headers look like — is read and
/// classified correctly.
@Suite("Content-checked .pem/.key candidates (ticket #8, claim 1)")
struct PlaintextPEMContentTests {

    /// A real RSA private key, PKCS8-encoded (`-----BEGIN PRIVATE KEY-----`),
    /// from `openssl genpkey` — not a hand-typed header, so this cannot pass
    /// by coincidentally matching the assumptions of the code under test.
    private static func realPrivateKeyPEM() throws -> String {
        try ProjectFixture.run(try opensslPath(), [
            "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048",
        ])
    }

    /// A real, self-signed public certificate for that same key — the exact
    /// shape a Let's Encrypt or internal CA directory puts next to a private
    /// key, and the false-positive case this whole content check exists to
    /// avoid flagging.
    private static func realCertificatePEM(for privateKeyPath: String) throws -> String {
        try ProjectFixture.run(try opensslPath(), [
            "req", "-new", "-x509", "-key", privateKeyPath,
            "-days", "1", "-subj", "/CN=sops-macos-gui-test", "-nodes",
        ])
    }

    private static func opensslPath() throws -> String {
        for candidate in ["/opt/homebrew/bin/openssl", "/usr/bin/openssl", "/usr/local/bin/openssl"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw ProjectFixture.FixtureError("openssl not found")
    }

    @Test("a real private key named .pem is a candidate")
    func realPrivateKeyPemIsCandidate() async throws {
        let root = try ProjectFixture.makeDirectory("pem-private")
        let key = try Self.realPrivateKeyPEM()
        try ProjectFixture.write(key, to: root, at: "privkey.pem")

        let scanned = await ProjectScanner.scan(root: root)
        #expect(scanned.plaintextCandidates.contains { $0.lastPathComponent == "privkey.pem" })
    }

    @Test("a real private key named .key is a candidate")
    func realPrivateKeyDotKeyIsCandidate() async throws {
        let root = try ProjectFixture.makeDirectory("key-private")
        let key = try Self.realPrivateKeyPEM()
        try ProjectFixture.write(key, to: root, at: "server.key")

        let scanned = await ProjectScanner.scan(root: root)
        #expect(scanned.plaintextCandidates.contains { $0.lastPathComponent == "server.key" })
    }

    /// The negative case that matters most: a real, valid public certificate,
    /// same extension as the secret above, must never be reported as a
    /// plaintext-leaked secret. This is the exact scenario named in
    /// `isPlaintextSecretCandidate`'s doc comment — `cert.pem` next to
    /// `privkey.pem` — and it is the false positive a name-only `*.pem` match
    /// would have produced.
    @Test("a real public certificate named .pem is never a candidate")
    func realCertificatePemIsNotACandidate() async throws {
        let root = try ProjectFixture.makeDirectory("pem-public")
        let keyURL = root.appendingPathComponent("throwaway-key.pem")
        let key = try Self.realPrivateKeyPEM()
        try key.write(to: keyURL, atomically: true, encoding: .utf8)

        let cert = try Self.realCertificatePEM(for: keyURL.path)
        try ProjectFixture.write(cert, to: root, at: "cert.pem")

        let scanned = await ProjectScanner.scan(root: root)
        #expect(!scanned.plaintextCandidates.contains { $0.lastPathComponent == "cert.pem" },
                "a public certificate was reported as a leaked secret")
    }

    /// An arbitrary text file that happens to be named `.key` (a product
    /// license key, a config value) and contains nothing resembling PEM
    /// material must not be flagged either — the content check is a
    /// requirement, not merely a bonus signal on top of the extension.
    @Test("an arbitrary text file named .key with no PEM content is not a candidate")
    func nonPEMDotKeyIsNotACandidate() async throws {
        let root = try ProjectFixture.makeDirectory("key-nonpem")
        try ProjectFixture.write("PRODUCT-LICENSE-KEY=ABCD-1234-EFGH-5678\n", to: root, at: "license.key")

        let scanned = await ProjectScanner.scan(root: root)
        #expect(!scanned.plaintextCandidates.contains { $0.lastPathComponent == "license.key" })
    }
}
