import Foundation
import SopsEngine
import Testing
@testable import SopsHealth

private struct Projects: ProjectSourceProviding {
    let projects: [InspectedProject]
}

private func encryptionFinding(_ findings: [HealthFinding]) -> HealthFinding {
    findings.first { $0.id.hasSuffix(".encryption") }!
}

private func run(_ root: URL) async -> [HealthFinding] {
    await ProjectHealthCheck(source: Projects(
        projects: [InspectedProject(name: "demo", rootPath: root.path)])).run()
}

private let leafPlainYAML = """
db:
    host: localhost
    password: hunter2
api_key: sk-live-abc123

"""

/// Ticket #5, claim 1: a file saved by the real `sops` CLI with an
/// `encrypted_regex` that never compiles ends up with a complete, valid
/// `sops:` metadata block — recipients, a valid MAC — over values that are
/// entirely in cleartext, because sops discards the compile error rather
/// than refusing. `recipientFinding` (the app's existing recipient check)
/// only compares recipient *sets* and reports this file as healthy;
/// `unencryptedLeavesFinding` is the only check that looks at the leaves
/// themselves. Every fixture here goes through the real bridge or the real
/// CLI — never a hand-written "encrypted-looking" string — the same
/// discipline `ProjectHealthCheckRealBridgeTests` established.
@Suite("ProjectHealthCheck unencrypted-leaves guard")
struct ProjectEncryptionLeafFindingTests {

    @Test("a genuinely encrypted file is OK")
    func genuinelyEncryptedFileIsOK() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        let key = try ProjectFixture.ageKeyPair()
        try ProjectFixture.write("creation_rules:\n  - age: \(key.public)\n", to: root, at: ".sops.yaml")
        try ProjectFixture.write(
            try ProjectFixture.encrypted(leafPlainYAML, to: [key.public]), to: root, at: "secrets.yaml")

        let finding = encryptionFinding(await run(root))
        #expect(finding.status == .ok)
        #expect(finding.detail.contains("genuinely encrypted"))
    }

    /// Task 5 (SOPS-38): `tree.encrypted` now carries dotenv files too, and
    /// this check must pass `sniffed.format` through to
    /// `SopsBridge.inspectLeafEncryption` rather than a hardcoded `.yaml` —
    /// otherwise a genuinely-encrypted dotenv file would fail to parse as
    /// YAML and fall into "unverifiable", which is honest but needlessly
    /// degraded now that the bridge can actually check it (Task 4's
    /// `gobridge.InspectLeafEncryption` already reads dotenv).
    @Test("a genuinely encrypted dotenv file is OK, not unverifiable")
    func genuinelyEncryptedDotenvFileIsOK() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        let key = try ProjectFixture.ageKeyPair()
        try ProjectFixture.write("creation_rules:\n  - age: \(key.public)\n", to: root, at: ".sops.yaml")
        try ProjectFixture.write(
            try ProjectFixture.encryptedDotenv("API_KEY=sk-live-abc123\n", to: [key.public]),
            to: root, at: "secrets.env")

        let finding = encryptionFinding(await run(root))
        #expect(finding.status == .ok, "got: \(finding.status), detail: \(finding.detail)")
        #expect(finding.detail.contains("genuinely encrypted"))
        #expect(!finding.detail.contains("could not determine"))
    }

    /// The core reproduction: a file this app never touched, produced
    /// entirely by the real `sops` binary with a rule that never compiled.
    @Test("a file the CLI produced with an uncompilable encrypted_regex is a problem, not an OK")
    func brokenEncryptedRegexFileIsAProblem() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        let key = try ProjectFixture.ageKeyPair()
        try ProjectFixture.write("creation_rules:\n  - age: \(key.public)\n", to: root, at: ".sops.yaml")
        let broken = try ProjectFixture.sopsCLIEncrypted(
            leafPlainYAML, age: key.public, agePrivateKey: key.private, encryptedRegex: "(unclosed")
        try ProjectFixture.write(broken, to: root, at: "secrets.yaml")

        let findings = await run(root)
        let finding = encryptionFinding(findings)
        #expect(finding.status == .problem)
        #expect(finding.detail.contains("secrets.yaml"))
        // Never quotes the actual exposed values — a finding is exactly the
        // kind of text that gets screenshotted or logged.
        #expect(!finding.detail.contains("hunter2"))
        #expect(!finding.detail.contains("sk-live-abc123"))
        // The existing recipient check must not be dragged down by this —
        // it is answering a different, still-true question (the recipient
        // set matches). Two independent findings, not one blurred verdict.
        let recipients = findings.first { $0.id.hasSuffix(".stale-recipients") }!
        #expect(recipients.status == .ok)
    }

    @Test("a file whose encrypted_regex deliberately narrows encryption is not flagged")
    func deliberateNarrowingIsNotFlagged() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        let key = try ProjectFixture.ageKeyPair()
        try ProjectFixture.write("creation_rules:\n  - age: \(key.public)\n", to: root, at: ".sops.yaml")
        let narrowed = try ProjectFixture.sopsCLIEncrypted(
            leafPlainYAML, age: key.public, agePrivateKey: key.private,
            encryptedRegex: "^(password|api_key)$")
        try ProjectFixture.write(narrowed, to: root, at: "secrets.yaml")

        let finding = encryptionFinding(await run(root))
        #expect(finding.status != .problem, "a deliberately partial rule must never be reported as the compile-failure bug")
    }

    @Test("no encrypted files yet is skipped, not a false OK")
    func noEncryptedFilesIsSkipped() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write(
            "creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n", to: root, at: ".sops.yaml")

        let finding = encryptionFinding(await run(root))
        guard case .skipped = finding.status else {
            Issue.record("expected skipped, got \(finding.status)")
            return
        }
    }

    @Test("the finding names that comments are not covered by sops's own integrity check")
    func commentCaveatIsAlwaysStated() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        let key = try ProjectFixture.ageKeyPair()
        try ProjectFixture.write("creation_rules:\n  - age: \(key.public)\n", to: root, at: ".sops.yaml")
        try ProjectFixture.write(
            try ProjectFixture.encrypted(leafPlainYAML, to: [key.public]), to: root, at: "secrets.yaml")

        let finding = encryptionFinding(await run(root))
        #expect(finding.detail.lowercased().contains("comment"))
    }

    @Test("a file too large to read in full is reported unverifiable, never guessed at")
    func oversizedFileIsUnverifiable() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        let key = try ProjectFixture.ageKeyPair()
        try ProjectFixture.write("creation_rules:\n  - age: \(key.public)\n", to: root, at: ".sops.yaml")
        // A real, fully-encrypted file, so if the size gate were absent this
        // would report OK — proving the gate is what produced the result,
        // not a coincidental read failure.
        let encrypted = try ProjectFixture.encrypted(leafPlainYAML, to: [key.public])
        try ProjectFixture.write(encrypted, to: root, at: "secrets.yaml")
        let fileURL = root.appendingPathComponent("secrets.yaml")
        let padding = String(repeating: "#", count: ProjectHealthCheck.maxLeafEncryptionCheckBytes + 1024)
        try (padding + "\n" + encrypted).write(to: fileURL, atomically: true, encoding: .utf8)

        let finding = encryptionFinding(await run(root))
        #expect(finding.status != .problem, "an unreadable-by-budget file must never be reported as the bug")
        #expect(finding.status != .ok, "a file this app declined to read cannot be vouched for")
    }
}
