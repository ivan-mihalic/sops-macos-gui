import Foundation
import ScratchCleanup
import Testing
@testable import SopsHealth

/// An **anchored** `path_regex` — one beginning with `^` — is the case every
/// other fixture in this target misses, and it is the case that fails.
///
/// sops decides which creation rule governs a file by stripping the config's
/// own directory off the file's path *as a literal prefix* and matching
/// `path_regex` against what is left (`config/config.go`'s
/// `parseCreationRuleForFile`). That only works when both paths are spelled
/// the same way. They are not: `FileManager.enumerator` hands back entries
/// with symlinks in the directory prefix already resolved — a root under
/// `/var` (itself a symlink to `/private/var`, which is where `$TMPDIR` and
/// plenty of real project roots live) enumerates as `/private/var/…` — while
/// the root keeps whatever spelling it was added under. The prefix strip is
/// then a no-op and every rule is matched against an *absolute* path.
///
/// Why no existing test caught it: `ProjectHealthCheckTests` writes
/// `path_regex: secrets/.*\.yaml$`, which is unanchored, so it happily
/// matches somewhere inside `/private/var/folders/…/secrets/prod.yaml` and
/// the check passes for the wrong reason. Anchor the same rule and the file
/// stops matching anything, so the health check reports that no creation rule
/// governs a file that one plainly does.
///
/// The identical defect was found and fixed in `ProjectRecipientApplier`
/// (see its `ruleMatchingPath`); this suite exists because the fix was never
/// carried across to `SopsHealth`, which calls
/// `SopsBridge.lookupCreationRule` with the same mismatched pair of spellings.
@Suite("ProjectHealthCheck with an anchored path_regex")
struct ProjectHealthCheckAnchoredPathRegexTests {

    @Test("an anchored path_regex still matches the files it governs")
    func anchoredRuleGovernsItsFiles() async throws {
        let root = try makeAnchoredProject(
            sopsYAML: """
            creation_rules:
              - path_regex: ^secrets/.*\\.yaml$
                age: \(anchoredDevKey)
            """,
            files: ["secrets/prod.yaml": anchoredEncryptedFile(recipients: [anchoredDevKey])])

        let findings = await ProjectHealthCheck(source: AnchoredFakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)])).run()
        let recipients = anchoredFinding(findings, suffix: "stale-recipients")

        // The rule governs `secrets/prod.yaml` and names exactly the key the
        // file is encrypted to, so there is nothing to report. Anything else
        // means the rule was matched against the wrong string.
        #expect(recipients.status == .ok)
        #expect(!recipients.detail.contains("no creation rule"))
    }

    /// The same project reached through a symlink, which is how a real root
    /// acquires two spellings — `$TMPDIR` under `/var` is one instance, but
    /// so is any project the user keeps behind a symlinked home, volume or
    /// checkout directory. Both names denote one directory, so both must
    /// reach the same verdict: a check whose answer depends on which of two
    /// names for one path the project happened to be added under is not a
    /// check.
    ///
    /// This builds the symlink explicitly rather than relying on `/var` being
    /// one, because Foundation's `resolvingSymlinksInPath()` only *removes* a
    /// leading `/private` and never adds one (see `ProjectHealthCheck`'s
    /// `canonicalPath`), so the two `/var` spellings cannot be told apart by
    /// asking Foundation — a premise check written that way silently proves
    /// nothing.
    @Test("the verdict does not depend on whether the root was added through a symlink")
    func bothSpellingsOfTheRootAgree() async throws {
        let real = try makeAnchoredProject(
            sopsYAML: """
            creation_rules:
              - path_regex: ^secrets/.*\\.yaml$
                age: \(anchoredDevKey)
            """,
            files: ["secrets/prod.yaml": anchoredEncryptedFile(recipients: [anchoredDevKey])])

        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("anchored-regex-link-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(link)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: real))
        defer { try? FileManager.default.removeItem(at: link) }

        // The premise, asserted rather than assumed: the two spellings really
        // are different strings naming the same directory.
        try #require(link.path != real)
        try #require(FileManager.default.fileExists(
            atPath: link.appendingPathComponent(".sops.yaml").path))

        for spelling in [real, link.path] {
            let findings = await ProjectHealthCheck(source: AnchoredFakeProjects(
                projects: [InspectedProject(name: "demo", rootPath: spelling)])).run()
            #expect(anchoredFinding(findings, suffix: "stale-recipients").status == .ok,
                    "root spelled \(spelling) reached a different verdict")
        }
    }
}

// MARK: - Fixtures

private struct AnchoredFakeProjects: ProjectSourceProviding {
    let projects: [InspectedProject]
}

/// A real, valid Bech32 age public key, as the rest of this target uses —
/// `.sops.yaml` is parsed by sops's own config loader, which rejects a
/// placeholder.
private let anchoredDevKey = "age1ykd0u99qxpdl4yr57lwqv5rt9e473p6hhdps2a5q5ddmt0x6ryaqkjpx4f"

private func makeAnchoredProject(sopsYAML: String, files: [String: String]) throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("anchored-regex-" + UUID().uuidString)
    ScratchDirectoryRegistry.shared.register(root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try ProjectFixture.gitInit(root)
    try sopsYAML.write(to: root.appendingPathComponent(".sops.yaml"),
                       atomically: true, encoding: .utf8)
    for (name, contents) in files {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    return root.path
}

/// Matches the field order the real bridge writes (`enc:` before
/// `recipient:`) — see `ProjectHealthCheckTests`' note on why that ordering
/// is not arbitrary.
private func anchoredEncryptedFile(recipients: [String]) -> String {
    let entries = recipients.map {
        "        - enc: |\n            -----BEGIN AGE ENCRYPTED FILE-----\n          recipient: \($0)\n"
    }
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

private func anchoredFinding(_ findings: [HealthFinding], suffix: String) -> HealthFinding {
    findings.first { $0.id.hasSuffix(suffix) }!
}
