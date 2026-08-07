import Foundation
import Testing
@testable import SopsHealth

private struct FakeProjects: ProjectSourceProviding {
    let projects: [InspectedProject]
}

/// Builds a throwaway project directory. Returns its root path.
///
/// Always a real `git init` repository: the plaintext-leak finding now asks
/// `git check-ignore` for its verdict rather than reading `.gitignore` lines
/// itself (see `GitIgnoreOracle`), so a fixture that is not a repository
/// legitimately produces "could not be determined" instead of an answer.
private func makeProject(
    sopsYAML: String?,
    files: [String: String] = [:],
    gitignore: String? = nil
) throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("project-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try ProjectFixture.gitInit(root)
    if let sopsYAML {
        try sopsYAML.write(to: root.appendingPathComponent(".sops.yaml"),
                           atomically: true, encoding: .utf8)
    }
    if let gitignore {
        try gitignore.write(to: root.appendingPathComponent(".gitignore"),
                            atomically: true, encoding: .utf8)
    }
    for (name, contents) in files {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    return root.path
}

// Both real, valid Bech32 age public keys (from `age-keygen`), not
// placeholders — `.sops.yaml` content now parses through sops's own config
// parser (see ProjectHealthCheck.swift), which validates the Bech32
// checksum of every `age:` value at config-load time. A syntactically
// key-shaped but checksum-invalid placeholder (e.g. repeated "age1qqqq...")
// used to be accepted by the old hand-rolled parser as an opaque string; the
// real parser correctly rejects it, which made every fixture using one fail
// to parse at all until they were replaced with real keys here.
private let devKey = "age1ykd0u99qxpdl4yr57lwqv5rt9e473p6hhdps2a5q5ddmt0x6ryaqkjpx4f"
private let serverKey = "age1f7ekyrshavjztvv5zfuvstkjqjhcry9cwk8lprwaxp49cz0cvsdssdfax0"

// The real sops CLI/bridge writes `enc:` before `recipient:` within each age
// entry (verified against a genuine SopsBridge.encryptYAML output — see
// ProjectHealthCheckRealBridgeTests.swift). This fixture mirrors that order
// rather than the reverse, so a hand-written fake doesn't quietly diverge
// from what a real .sops-encrypted file looks like.
private func encryptedFile(recipients: [String]) -> String {
    let entries = recipients.map { "        - enc: |\n            -----BEGIN AGE ENCRYPTED FILE-----\n          recipient: \($0)\n" }
    return """
    password: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
    sops:
        age:
    \(entries.joined())
        lastmodified: "2026-08-06T14:00:00Z"
        mac: ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
        version: 3.13.3
    """
}

private func finding(_ findings: [HealthFinding], suffix: String) -> HealthFinding {
    findings.first { $0.id.hasSuffix(suffix) }!
}

@Suite("ProjectHealthCheck")
struct ProjectHealthCheckTests {

    @Test("with no projects added the check is skipped, not failing")
    func noProjectsIsSkipped() async {
        let findings = await ProjectHealthCheck(source: FakeProjects(projects: [])).run()
        #expect(findings.count == 1)
        guard case .skipped = findings[0].status else {
            Issue.record("expected skipped, got \(findings[0].status)")
            return
        }
    }

    @Test("a project with no .sops.yaml is a warning")
    func missingSopsYAMLWarns() async throws {
        let root = try makeProject(sopsYAML: nil)
        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        #expect(finding(await check.run(), suffix: "sops-yaml").status == .warning)
    }

    @Test("an unparseable .sops.yaml is a problem")
    func malformedSopsYAMLIsAProblem() async throws {
        let root = try makeProject(sopsYAML: "creation_rules:\n  - this: [is: not: valid\n")
        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        #expect(finding(await check.run(), suffix: "sops-yaml").status == .problem)
    }

    @Test("a valid .sops.yaml with every file matching its rule is OK")
    func healthyProjectIsOK() async throws {
        let root = try makeProject(
            sopsYAML: """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(devKey),\(serverKey)
            """,
            files: ["secrets/prod.yaml": encryptedFile(recipients: [devKey, serverKey])])
        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        let findings = await check.run()
        #expect(finding(findings, suffix: "sops-yaml").status == .ok)
        #expect(finding(findings, suffix: "stale-recipients").status == .ok)
    }

    @Test("a file encrypted to a recipient no longer in .sops.yaml is a problem")
    func staleRecipientIsAProblem() async throws {
        let removedColleague = "age1z7wqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
        let root = try makeProject(
            sopsYAML: """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(devKey)
            """,
            files: ["secrets/prod.yaml": encryptedFile(recipients: [devKey, removedColleague])])
        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))

        let stale = finding(await check.run(), suffix: "stale-recipients")
        #expect(stale.status == .problem)
        #expect(stale.detail.contains("secrets/prod.yaml"))
        // Removing a recipient does not un-leak the old value.
        #expect(stale.remediation?.explanation.lowercased().contains("rotate") == true)
    }

    @Test("a file missing a recipient its rule declares is a problem")
    func missingRecipientIsAProblem() async throws {
        let root = try makeProject(
            sopsYAML: """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(devKey),\(serverKey)
            """,
            files: ["secrets/prod.yaml": encryptedFile(recipients: [devKey])])
        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        #expect(finding(await check.run(), suffix: "stale-recipients").status == .problem)
    }

    @Test("a plaintext .env inside the project that is not gitignored is a problem")
    func ungitignoredPlaintextIsAProblem() async throws {
        let root = try makeProject(
            sopsYAML: "creation_rules:\n  - age: \(devKey)\n",
            files: [".env": "API_KEY=sk-live-abc123\n"],
            gitignore: "node_modules/\n")
        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))

        let leak = finding(await check.run(), suffix: "gitignore")
        #expect(leak.status == .problem)
        #expect(leak.detail.contains(".env"))
        // The value must never appear in the finding.
        #expect(!leak.detail.contains("sk-live-abc123"))
    }

    @Test("a gitignored plaintext .env is OK")
    func gitignoredPlaintextIsOK() async throws {
        let root = try makeProject(
            sopsYAML: "creation_rules:\n  - age: \(devKey)\n",
            files: [".env": "API_KEY=sk-live-abc123\n"],
            gitignore: ".env\n")
        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        #expect(finding(await check.run(), suffix: "gitignore").status == .ok)
    }

    // The app has only public keys. It cannot prove a colleague can decrypt.
    @Test("the recipient finding says it checked the key list, not decryptability")
    func wordingIsHonestAboutWhatWasVerified() async throws {
        let root = try makeProject(
            sopsYAML: "creation_rules:\n  - path_regex: secrets/.*\\.yaml$\n    age: \(devKey)\n",
            files: ["secrets/prod.yaml": encryptedFile(recipients: [devKey])])
        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))

        let text = finding(await check.run(), suffix: "stale-recipients").detail.lowercased()
        #expect(!text.contains("can decrypt"))
    }
}
