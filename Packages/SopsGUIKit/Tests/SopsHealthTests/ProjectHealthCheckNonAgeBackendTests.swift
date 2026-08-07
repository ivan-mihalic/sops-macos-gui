import Foundation
import Testing
import SopsEngine
@testable import SopsHealth

// MARK: - Fixture plumbing

private struct FakeProjects: ProjectSourceProviding {
    let projects: [InspectedProject]
}

private func makeProject(sopsYAML: String, files: [String: String]) throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("backend-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try sopsYAML.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
    for (name, contents) in files {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    return root.path
}

private func run(_ path: String, _ args: [String], environment: [String: String] = [:]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    let err = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "\(path) \(args.joined(separator: " ")) exited \(process.terminationStatus): \(String(decoding: err, as: UTF8.self))",
        ])
    }
    return String(decoding: out, as: UTF8.self)
}

/// A real, throwaway GPG key and a real sops --pgp encrypted file, produced
/// by the actual `gpg` and `sops` binaries — not a hand-typed fixture. This
/// is what let the reviewer catch the bug this file guards against: real PGP
/// metadata has no `recipient:` field at all, only `fp:`, so a parser that
/// only ever looks for `recipient:` silently sees "zero recipients" and
/// calls it a match.
private enum RealPGPFixture {
    static func makeEncryptedFile(plaintext: String) throws -> (encrypted: String, fingerprint: String) {
        // gpg-agent listens on a Unix domain socket under GNUPGHOME, and
        // sockaddr_un caps that path at ~104 bytes on macOS. The sandboxed
        // FileManager.default.temporaryDirectory (/var/folders/.../T/) is
        // already long enough that appending "gnupg-<uuid>/S.gpg-agent"
        // overflows it — gpg then fails with the misleading "File name too
        // long" / "No agent running", not an obvious path-length error. A
        // short, direct /tmp path avoids that entirely.
        let short = String((0..<8).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        let gnupgHome = URL(fileURLWithPath: "/tmp/gnupg-\(short)")
        try FileManager.default.createDirectory(
            at: gnupgHome, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let batchFile = gnupgHome.appendingPathComponent("genkey.batch")
        try """
        %no-protection
        Key-Type: RSA
        Key-Length: 2048
        Name-Real: SopsHealth Test
        Name-Email: sopshealth-test@example.invalid
        Expire-Date: 0
        %commit
        """.write(to: batchFile, atomically: true, encoding: .utf8)

        _ = try run("/opt/homebrew/bin/gpg", ["--batch", "--gen-key", batchFile.path],
                    environment: ["GNUPGHOME": gnupgHome.path])

        let colonOutput = try run("/opt/homebrew/bin/gpg",
                                  ["--list-secret-keys", "--with-colons"],
                                  environment: ["GNUPGHOME": gnupgHome.path])
        guard let fprLine = colonOutput.split(separator: "\n").first(where: { $0.hasPrefix("fpr:") }) else {
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "no fingerprint in gpg output"])
        }

        // Under Swift Testing's parallel test execution, running multiple
        // real key generations concurrently occasionally raced: `sops
        // --pgp --encrypt` (below) would fail with "key ... is not
        // available in keyring" moments after this same key was already
        // confirmed present via --list-secret-keys above. Killing this
        // GNUPGHOME's gpg-agent here forces the next invocation (sops's own
        // keyring read) to start fresh against the on-disk keybox rather
        // than any in-flight agent state from concurrent key generation
        // elsewhere. Scoped to this test's own GNUPGHOME only — never
        // touches a real gpg-agent on the developer's machine.
        _ = try? run("/opt/homebrew/bin/gpgconf", ["--kill", "gpg-agent"],
                     environment: ["GNUPGHOME": gnupgHome.path])
        // gpg's --with-colons format has empty fields between the leading
        // colons (e.g. "fpr:::::::::FINGERPRINT:") — the default
        // `split(separator:)` omits empty subsequences, which collapses
        // those and shifts every index after them. `omittingEmptySubsequences:
        // false` is required to land on the real field 10 (index 9).
        let fields = fprLine.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count > 9 else {
            throw NSError(domain: "test", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "gpg fpr line had \(fields.count) fields, expected >9: \(fprLine)",
            ])
        }
        let fingerprint = fields[9].trimmingCharacters(in: .whitespaces)

        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("pgp-src-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let plainFile = workDir.appendingPathComponent("secrets.yaml")
        try plaintext.write(to: plainFile, atomically: true, encoding: .utf8)

        // Under Swift Testing's parallel execution, this specific step
        // occasionally races: sops reports the just-generated key "is not
        // available in keyring" even though --list-secret-keys above (and
        // the gpgconf --kill retry above) both saw it. This is not this
        // app's code failing — it's real gpg/gpg-agent process contention
        // under concurrent key generation, external to anything under
        // test — so a bounded retry against the same already-generated key
        // is the honest fix: it doesn't change what's verified, only
        // absorbs environment timing that has nothing to do with the
        // check's own logic.
        var lastError: Error?
        for attempt in 1...3 {
            do {
                let encrypted = try run("/opt/homebrew/bin/sops",
                                        ["--pgp", fingerprint, "--encrypt", plainFile.path],
                                        environment: ["GNUPGHOME": gnupgHome.path])
                return (encrypted, fingerprint)
            } catch {
                lastError = error
                if attempt < 3 { Thread.sleep(forTimeInterval: 0.3) }
            }
        }
        throw lastError!
    }
}

/// Hand-written fixtures for the backends that can't be produced by a real
/// binary in this environment (no AWS/GCP/Azure/Vault credentials here).
/// The field names are not guessed: they're read verbatim from
/// `stores.metadata` in `github.com/getsops/sops/v3@v3.13.3`'s
/// `stores/stores.go` — the exact pinned version `Engine/` embeds — so this
/// is the shape sops actually writes, even though this particular file
/// wasn't produced by running it live.
private enum BackendFixtures {
    static func kms() -> String {
        """
        password: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
        sops:
            kms:
                - arn: arn:aws:kms:us-east-1:000000000000:key/test
                  created_at: "2026-08-06T00:00:00Z"
                  enc: AQICAHhexamplenotreal==
            lastmodified: "2026-08-06T00:00:00Z"
            mac: ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
            version: 3.13.3
        """
    }

    static func gcpKMS() -> String {
        """
        password: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
        sops:
            gcp_kms:
                - resource_id: projects/test/locations/global/keyRings/test/cryptoKeys/test
                  created_at: "2026-08-06T00:00:00Z"
                  enc: CiQAexamplenotreal==
            lastmodified: "2026-08-06T00:00:00Z"
            mac: ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
            version: 3.13.3
        """
    }

    static func azureKeyVault() -> String {
        """
        password: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
        sops:
            azure_kv:
                - vault_url: https://test.vault.azure.net
                  name: test-key
                  version: 0000000000000000000000000000000
                  created_at: "2026-08-06T00:00:00Z"
                  enc: notarealencrypteddatakey==
            lastmodified: "2026-08-06T00:00:00Z"
            mac: ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
            version: 3.13.3
        """
    }

    static func hcVault() -> String {
        """
        password: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
        sops:
            hc_vault:
                - vault_address: https://vault.example.invalid:8200
                  engine_path: transit
                  key_name: test
                  created_at: "2026-08-06T00:00:00Z"
                  enc: vault:v1:notarealencrypteddatakey==
            lastmodified: "2026-08-06T00:00:00Z"
            mac: ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
            version: 3.13.3
        """
    }

    static func keyGroups(ageRecipient: String) -> String {
        """
        password: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
        sops:
            key_groups:
                - pgp:
                    - fp: 0000000000000000000000000000000000AAAA
                      created_at: "2026-08-06T00:00:00Z"
                      enc: notarealpgpmessage==
                  age:
                    - recipient: \(ageRecipient)
                      enc: notarealagekey==
            lastmodified: "2026-08-06T00:00:00Z"
            mac: ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
            version: 3.13.3
        """
    }
}

private func finding(_ findings: [HealthFinding], suffix: String) -> HealthFinding {
    findings.first { $0.id.hasSuffix(suffix) }!
}

private let devKey = "age1ykd0u99qxpdl4yr57lwqv5rt9e473p6hhdps2a5q5ddmt0x6ryaqkjpx4f"

// MARK: - Direct tests of EncryptedFileMetadata (no ProjectHealthCheck
// involved). This is the encrypted-file-metadata scanner, a materially
// different and narrower problem than parsing a user-authored .sops.yaml —
// see EncryptedFileMetadata's doc comment in ProjectHealthCheck.swift. It is
// NOT what was replaced by SopsBridge.lookupCreationRule.

@Suite("EncryptedFileMetadata.nonAgeBackends against real and grounded fixtures")
struct EncryptedFileMetadataNonAgeBackendTests {

    @Test("a real sops --pgp encrypted file has no age recipient, and is recognised as pgp-protected")
    func realPGPFile() throws {
        let (encrypted, fingerprint) = try RealPGPFixture.makeEncryptedFile(
            plaintext: "password: hunter2\napi_key: sk-live-abc123\n")

        #expect(EncryptedFileMetadata.recipients(inEncryptedFile: encrypted).isEmpty)
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: encrypted) == ["pgp"])
        // Sanity: the fingerprint really is in the file, just not as `recipient:`.
        #expect(encrypted.contains(fingerprint))
        #expect(!encrypted.contains("recipient:"))
    }

    @Test("kms, gcp_kms, azure_kv, and hc_vault are each recognised by their real field name")
    func otherBackends() {
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: BackendFixtures.kms()) == ["kms"])
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: BackendFixtures.gcpKMS()) == ["gcp_kms"])
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: BackendFixtures.azureKeyVault()) == ["azure_kv"])
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: BackendFixtures.hcVault()) == ["hc_vault"])
    }

    @Test("key_groups is recognised even when the group also contains a real age recipient")
    func keyGroupsWithMixedAge() {
        let text = BackendFixtures.keyGroups(ageRecipient: devKey)
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: text) == ["key_groups"])
        // The age recipient nested inside the key group is not something
        // recipients(inEncryptedFile:) is asked to reconcile against a rule's
        // flat age: list — key_groups is flagged wholesale as unverifiable
        // rather than partially trusted. It's still readable here, though,
        // which is why this app cannot claim "zero recipients" for it either.
        #expect(EncryptedFileMetadata.recipients(inEncryptedFile: text) == [devKey])
    }

    @Test("a plaintext field named kms in the user's own data is not mistaken for sops metadata")
    func ownDataFieldNamedLikeABackendIsIgnored() {
        let text = """
        kms: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
        sops:
            age:
                - recipient: \(devKey)
                  enc: notarealagekey==
            lastmodified: "2026-08-06T00:00:00Z"
            mac: ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
            version: 3.13.3
        """
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: text).isEmpty)
    }

    // Regression: recipients(inEncryptedFile:) used to scan the *whole*
    // file for any line starting with "recipient:", not just inside the
    // sops: block. sops only ever encrypts VALUES, never KEYS — a project's
    // own plaintext data can legitimately have a field literally named
    // "recipient" (an email/payment "recipient" field is completely
    // ordinary), which after encryption becomes "recipient: ENC[...]" in
    // cleartext (only the value is hidden). The old, unscoped scan would
    // have swallowed that whole ENC[...] blob as if it were a real age
    // public key. Now scoped to the sops: block via the same
    // sopsBlockLines(in:) helper nonAgeBackends already used.
    @Test("a plaintext field named recipient in the user's own data is never mistaken for an age recipient")
    func ownDataFieldNamedRecipientIsNotMistakenForAnAgeRecipient() {
        let text = """
        recipient: ENC[AES256_GCM,data:not-a-real-age-key-this-is-someones-email,iv:def,tag:ghi,type:str]
        password: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
        sops:
            age:
                - recipient: \(devKey)
                  enc: notarealagekey==
            lastmodified: "2026-08-06T00:00:00Z"
            mac: ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
            version: 3.13.3
        """
        let recipients = EncryptedFileMetadata.recipients(inEncryptedFile: text)
        #expect(recipients == [devKey])
        #expect(!recipients.contains { $0.hasPrefix("ENC[") })
    }

    @Test("an explicitly empty backend, pgp: [], is not flagged")
    func explicitlyEmptyBackendIsNotFlagged() {
        let text = """
        password: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
        sops:
            pgp: []
            age:
                - recipient: \(devKey)
                  enc: notarealagekey==
            lastmodified: "2026-08-06T00:00:00Z"
            mac: ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
            version: 3.13.3
        """
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: text).isEmpty)
    }
}

// MARK: - End-to-end: ProjectHealthCheck must never say .ok about a backend it cannot read

@Suite("ProjectHealthCheck against non-age backends")
struct ProjectHealthCheckNonAgeBackendTests {

    @Test("a pgp-only rule protecting a real pgp-encrypted file is .unknown, never a confident .ok")
    func pgpOnlyRuleIsUnknownNotOK() async throws {
        let (encrypted, _) = try RealPGPFixture.makeEncryptedFile(plaintext: "password: hunter2\n")
        let root = try makeProject(
            sopsYAML: """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                pgp: 0000000000000000000000000000000000AAAA
            """,
            files: ["secrets/prod.yaml": encrypted])

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        let stale = finding(await check.run(), suffix: "stale-recipients")

        guard case .unknown = stale.status else {
            Issue.record("expected .unknown, got \(stale.status) — a pgp-only file must never be reported as a confident match")
            return
        }
        #expect(stale.detail.lowercased().contains("pgp"))
        #expect(stale.status != .ok)
    }

    // History, because this capability was removed and then put back and the
    // comment that used to sit here outlived the removal: when `.sops.yaml`
    // parsing moved to `SopsBridge.lookupCreationRule`, a rule declaring a
    // non-age backend with *zero* matching files stopped being flagged —
    // that call resolves the rule governing one target file, and sops's
    // config API has no enumerate-every-rule entry point. The result was a
    // blanket `.ok` about a configuration this app cannot read at all.
    // `SopsBridge.inspectConfigBackends` was added to close it; see
    // `ProjectHealthCheckDeclaredBackendTests` at the bottom of this file for
    // the tests that pin it, and `ProjectHealthCheck.recipientFinding`'s doc
    // comment for how the three "cannot evaluate" signals combine.

    // The blanket sentence the .ok branch produces. No finding about a config
    // this app cannot fully read may ever contain it — that claim is the whole
    // defect this suite guards against.
    static let blanketOK = "every file's key list matches"

    @Test("a mixed age+pgp file still gets its age recipients checked, and a genuine age mismatch still wins as .problem")
    func mixedBackendFileStillChecksItsAgePart() async throws {
        // key_groups fixture has a real, readable age recipient (devKey) that
        // does NOT match the rule's declared age key, so this must surface
        // as .problem (a real, actionable mismatch), not get swallowed by
        // the "unverifiable" bucket.
        // A real, valid Bech32 age key (from `age-keygen`), distinct from
        // devKey — this goes into .sops.yaml, which is now parsed by sops's
        // own config parser and validates the checksum of every age: value
        // at load time. A placeholder like "age1qqqq..." fails to parse.
        let otherKey = "age1yd590dqkgjwjd558dpn5mpm2kf4p3nc94eswd09yruunaq8a2udqnxjdhz"
        let root = try makeProject(
            sopsYAML: """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(otherKey)
            """,
            files: ["secrets/prod.yaml": BackendFixtures.keyGroups(ageRecipient: devKey)])

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        let stale = finding(await check.run(), suffix: "stale-recipients")

        #expect(stale.status == .problem)
        #expect(stale.detail.contains(devKey))
    }
}

// MARK: - A rule the app cannot evaluate is invisible to a per-file lookup

/// `SopsBridge.lookupCreationRule` answers "which rule governs *this file*".
/// A creation rule declaring pgp/KMS/Vault that no file currently matches is
/// therefore invisible to it, and the recipients finding used to fold that
/// silence into `.ok`: *"Checked every encrypted file's recipient key list
/// against the rule that governs it — every file's key list matches."* Said
/// about a configuration the app cannot evaluate at all, that is the exact
/// failure PROPOSAL.md §6 D forbids:
///
/// > A rule using a backend the app cannot evaluate (pgp, KMS, Vault) reports
/// > *Skipped* naming that backend; it must never report OK about a
/// > configuration it cannot read.
///
/// `SopsBridge.inspectConfigBackends` is the whole-config counterpart that
/// closes it. These are the reviewer's own three reproductions.
@Suite("ProjectHealthCheck against a backend declared but not yet used by any file")
struct ProjectHealthCheckDeclaredBackendTests {

    /// A real, freshly generated age public key — a `.sops.yaml` is now parsed
    /// by sops's own config parser, which validates every `age:` value's
    /// Bech32 checksum at load time, so a placeholder would fail the whole
    /// config to load.
    static func realAgePublicKey() throws -> String {
        let output = try run("/opt/homebrew/bin/age-keygen", [])
        for line in output.split(separator: "\n") where line.hasPrefix("# public key: ") {
            return String(line.dropFirst("# public key: ".count))
        }
        throw NSError(domain: "test", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "age-keygen produced no public key line"])
    }

    @Test("a pgp-only config with no encrypted files at all is never a confident .ok")
    func pgpOnlyConfigWithNoFiles() async throws {
        let root = try makeProject(
            sopsYAML: """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                pgp: 0000000000000000000000000000000000AAAA
            """,
            files: [:])

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        let stale = finding(await check.run(), suffix: "stale-recipients")

        guard case .unknown = stale.status else {
            Issue.record("expected .unknown, got \(stale.status) — detail: \(stale.detail)")
            return
        }
        #expect(stale.detail.contains("PGP"))
        #expect(!stale.detail.contains(ProjectHealthCheckNonAgeBackendTests.blanketOK))
    }

    @Test("a healthy age rule alongside a pgp rule with no files reports what was checked, and does not vouch for the rest")
    func mixedHealthyAgeRuleAndUnusedPGPRule() async throws {
        let key = try Self.realAgePublicKey()
        // Genuinely and correctly encrypted to that same real recipient.
        let encrypted = try SopsBridge.encryptYAML("password: hunter2\n", recipients: [key])

        let root = try makeProject(
            sopsYAML: """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(key)
              - path_regex: legacy/.*\\.yaml$
                pgp: 0000000000000000000000000000000000AAAA
            """,
            files: ["secrets/prod.yaml": encrypted])

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        let stale = finding(await check.run(), suffix: "stale-recipients")

        guard case .unknown = stale.status else {
            Issue.record("expected .unknown, got \(stale.status) — detail: \(stale.detail)")
            return
        }
        // The user's healthy age rule genuinely was checked, and the finding
        // says so — withholding the verdict must not erase the part that was
        // verified.
        #expect(stale.detail.contains("Checked 1 encrypted file"))
        #expect(stale.detail.contains("PGP"))
        #expect(!stale.detail.contains(ProjectHealthCheckNonAgeBackendTests.blanketOK))
        // Nothing about a backend the app cannot read may read as an accusation.
        #expect(!stale.detail.contains("updatekeys"))
        #expect(!stale.detail.lowercased().contains("stale"))
    }

    @Test("a KMS/Vault-only config with no encrypted files names both backends and stays .unknown")
    func cloudBackendsOnlyWithNoFiles() async throws {
        let root = try makeProject(
            sopsYAML: """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                kms: arn:aws:kms:us-east-1:000000000000:key/test
                hc_vault_transit_uri: https://vault.example.invalid:8200/v1/transit/keys/test
            """,
            files: [:])

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        let stale = finding(await check.run(), suffix: "stale-recipients")

        guard case .unknown = stale.status else {
            Issue.record("expected .unknown, got \(stale.status) — detail: \(stale.detail)")
            return
        }
        #expect(stale.detail.contains("AWS KMS"))
        #expect(stale.detail.contains("HashiCorp Vault"))
        #expect(!stale.detail.contains(ProjectHealthCheckNonAgeBackendTests.blanketOK))
    }

    /// The other half of the contract: withholding `.ok` must stay narrow. A
    /// project that really is age-only, with a real encrypted file matching
    /// its rule, must still get a confident, unqualified OK — a check that
    /// hedges about everything is as useless as one that vouches for
    /// everything.
    @Test("an age-only project with a genuinely matching file still reports a confident .ok")
    func ageOnlyProjectIsStillOK() async throws {
        let key = try Self.realAgePublicKey()
        let encrypted = try SopsBridge.encryptYAML("password: hunter2\n", recipients: [key])
        let root = try makeProject(
            sopsYAML: """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(key)
            """,
            files: ["secrets/prod.yaml": encrypted])

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        let stale = finding(await check.run(), suffix: "stale-recipients")

        #expect(stale.status == .ok, "detail: \(stale.detail)")
    }

    /// Decision, encoded as a test: a `key_groups:` block holding only age
    /// recipients is NOT treated as unevaluable. sops normalizes key groups
    /// into the same key-group list a flat rule produces, so those recipients
    /// are read and compared like any others — raising a caveat about them
    /// would withhold a verdict this app is fully able to reach.
    ///
    /// This holds end to end for a *single* key group, and that is not an
    /// accident of this fixture: real `sops --encrypt` against a one-group
    /// age-only rule writes a plain `age:` block into the file's metadata, no
    /// `key_groups:` key at all (verified against the real binary; output in
    /// the round-4 report). Two or more groups — i.e. Shamir — do emit a
    /// literal `key_groups:`, which the *file-level* scanner
    /// `EncryptedFileMetadata.nonAgeBackends` still flags wholesale, so that
    /// narrower case reaches `.unknown` once a real file exists. Pre-existing
    /// and deliberately out of scope here; recorded in the report.
    @Test("a key group holding only age recipients does not withhold the verdict")
    func ageOnlyKeyGroupStillReportsOK() async throws {
        let key = try Self.realAgePublicKey()
        let encrypted = try SopsBridge.encryptYAML("password: hunter2\n", recipients: [key])
        let root = try makeProject(
            sopsYAML: """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                key_groups:
                  - age:
                      - \(key)
            """,
            files: ["secrets/prod.yaml": encrypted])

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        let stale = finding(await check.run(), suffix: "stale-recipients")

        #expect(stale.status == .ok, "detail: \(stale.detail)")
    }
}
