import Foundation
import Testing
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

        let encrypted = try run("/opt/homebrew/bin/sops",
                                ["--pgp", fingerprint, "--encrypt", plainFile.path],
                                environment: ["GNUPGHOME": gnupgHome.path])
        return (encrypted, fingerprint)
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

// MARK: - Direct parser tests (no ProjectHealthCheck involved)

@Suite("SopsConfig.nonAgeBackends against real and grounded fixtures")
struct SopsConfigNonAgeBackendParsingTests {

    @Test("a real sops --pgp encrypted file has no age recipient, and is recognised as pgp-protected")
    func realPGPFile() throws {
        let (encrypted, fingerprint) = try RealPGPFixture.makeEncryptedFile(
            plaintext: "password: hunter2\napi_key: sk-live-abc123\n")

        #expect(SopsConfig.recipients(inEncryptedFile: encrypted).isEmpty)
        #expect(SopsConfig.nonAgeBackends(inEncryptedFile: encrypted) == ["pgp"])
        // Sanity: the fingerprint really is in the file, just not as `recipient:`.
        #expect(encrypted.contains(fingerprint))
        #expect(!encrypted.contains("recipient:"))
    }

    @Test("kms, gcp_kms, azure_kv, and hc_vault are each recognised by their real field name")
    func otherBackends() {
        #expect(SopsConfig.nonAgeBackends(inEncryptedFile: BackendFixtures.kms()) == ["kms"])
        #expect(SopsConfig.nonAgeBackends(inEncryptedFile: BackendFixtures.gcpKMS()) == ["gcp_kms"])
        #expect(SopsConfig.nonAgeBackends(inEncryptedFile: BackendFixtures.azureKeyVault()) == ["azure_kv"])
        #expect(SopsConfig.nonAgeBackends(inEncryptedFile: BackendFixtures.hcVault()) == ["hc_vault"])
    }

    @Test("key_groups is recognised even when the group also contains a real age recipient")
    func keyGroupsWithMixedAge() {
        let text = BackendFixtures.keyGroups(ageRecipient: devKey)
        #expect(SopsConfig.nonAgeBackends(inEncryptedFile: text) == ["key_groups"])
        // The age recipient nested inside the key group is not something
        // recipients(inEncryptedFile:) is asked to reconcile against a rule's
        // flat age: list — key_groups is flagged wholesale as unverifiable
        // rather than partially trusted. It's still readable here, though,
        // which is why this app cannot claim "zero recipients" for it either.
        #expect(SopsConfig.recipients(inEncryptedFile: text) == [devKey])
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
        #expect(SopsConfig.nonAgeBackends(inEncryptedFile: text).isEmpty)
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
        #expect(SopsConfig.nonAgeBackends(inEncryptedFile: text).isEmpty)
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

    @Test("a rule that declares kms alongside age is unknown even with zero files using it yet")
    func ruleDeclaringBackendWithNoMatchingFileIsStillFlagged() async throws {
        let root = try makeProject(
            sopsYAML: """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(devKey)
                kms: arn:aws:kms:us-east-1:000000000000:key/test
            """,
            files: [:])

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        let stale = finding(await check.run(), suffix: "stale-recipients")

        guard case .unknown = stale.status else {
            Issue.record("expected .unknown, got \(stale.status)")
            return
        }
        #expect(stale.detail.lowercased().contains("kms"))
    }

    @Test("a mixed age+pgp file still gets its age recipients checked, and a genuine age mismatch still wins as .problem")
    func mixedBackendFileStillChecksItsAgePart() async throws {
        // key_groups fixture has a real, readable age recipient (devKey) that
        // does NOT match the rule's declared age key, so this must surface
        // as .problem (a real, actionable mismatch), not get swallowed by
        // the "unverifiable" bucket.
        let otherKey = "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
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
