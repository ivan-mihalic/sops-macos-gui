import Foundation
import ScratchCleanup
import SopsEngine
import SopsHealth
import Testing

@testable import SopsProjects

/// #18 item 1: `ProjectRecipientApplier.ruleMatchingPath` and
/// `ProjectHealthCheck`'s own (private, local) equivalent are two
/// independently-written answers to "what spelling of this file's path does
/// `SopsBridge.lookupCreationRule` need to match an anchored `path_regex`
/// against". Both exist because the *naive* answer — the path as
/// `FileManager.enumerator` hands it back — disagrees with `projectRoot`'s
/// own spelling whenever a symlink sits between them (`/var` vs.
/// `/private/var`, which is where `$TMPDIR` itself lives), and each was
/// found and fixed **separately**, in that order: `ProjectRecipientApplier`
/// first, then `ProjectHealthCheck` months later, in its own dedicated
/// `ProjectHealthCheckAnchoredPathRegexTests.swift` whose doc comment says so
/// explicitly ("the fix was never carried across").
///
/// Two independently-maintained fixes for one bug is exactly the situation
/// where a third consumer that needs the identical fix and does not get it
/// looks, to every existing test file, like nothing changed — each file only
/// ever asked its own type about its own fixture. This file asks a
/// **different** question: given the one project fixture that reproduces the
/// original bug (an anchored rule, a root reached through `$TMPDIR`'s own
/// `/var` symlink), do `ProjectHealthCheck` and `ProjectRecipientApplier`
/// **agree** that the rule governs the file? Not by comparing the two
/// `ruleMatchingPath` implementations' string output directly — they are
/// deliberately not the same string (`ProjectRecipientApplier`'s resolves
/// symlinks on both sides; `ProjectHealthCheck`'s re-roots the relative name
/// onto the caller's own spelling of `configPath`, on purpose — see
/// `ProjectHealthCheck.ruleMatchingPath`'s own doc comment for why: `configPath`
/// has to stay openable). What has to agree, and what a user actually
/// experiences as one fact about one project, is the *outcome*: is this file
/// governed, and by whom.
@Suite("Rule matching parity — ProjectHealthCheck and ProjectRecipientApplier agree on an anchored rule")
struct RuleMatchingPathParityTests {

    private struct ParityFakeProjects: ProjectSourceProviding {
        let projects: [InspectedProject]
    }

    /// Builds the project entirely under `FileManager.default.temporaryDirectory`
    /// — `/var/folders/…`, itself reached through the `/var` → `/private/var`
    /// symlink — rather than constructing an explicit symlink, because that is
    /// the exact root every test in this suite (and a good number of real
    /// projects, per `CanonicalPath`'s own doc comment) already lives under.
    /// No extra fixture step is required to reproduce the original bug's
    /// precondition; it is already true of `$TMPDIR` on this machine.
    private func makeProject(owner: AgeKeyPair) throws -> URL {
        let root = try applierScratchDirectory("rule-matching-parity")
        let configText = """
            creation_rules:
              - path_regex: ^secrets/.*\\.yaml$
                age:
                  - \(owner.public)
            """
        try configText.write(
            to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let secrets = root.appendingPathComponent("secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        let encrypted = try SopsBridge.encryptYAML(applierPlainYAML, recipients: [owner.public])
        try encrypted.write(to: secrets.appendingPathComponent("prod.yaml"), atomically: true, encoding: .utf8)
        return root
    }

    @Test("both agree the file is governed, and by the same recipient")
    func bothAgreeTheFileIsGoverned() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try makeProject(owner: owner)

        // ProjectHealthCheck's side: the stale-recipients finding must be
        // .ok, and must not fall back to "no rule governs it" — the exact
        // symptom `ProjectHealthCheckAnchoredPathRegexTests` pins for this
        // type alone.
        let findings = await ProjectHealthCheck(source: ParityFakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root.path)])).run()
        let recipientFinding = try #require(findings.first { $0.id.hasSuffix(".stale-recipients") })
        #expect(recipientFinding.status == .ok,
                "ProjectHealthCheck did not recognize the anchored rule as governing the file: \(recipientFinding.detail)")
        #expect(!recipientFinding.detail.contains("no creation rule"))

        // ProjectRecipientApplier's side: the same file must land in
        // matchedFiles, not unmatchedFiles.
        let plan = await ProjectRecipientApplier().plan(projectRoot: root, recipients: [owner.public])
        #expect(plan.configError == nil)
        #expect(plan.matchedFiles.map(\.lastPathComponent) == ["prod.yaml"],
                "ProjectRecipientApplier did not recognize the anchored rule as governing the file")
        #expect(plan.unmatchedFiles.isEmpty)
        #expect(plan.configRecipients == [owner.public])
    }
}
