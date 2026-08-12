import Foundation
import ScratchCleanup
import SopsEngine
import Testing

@testable import SopsProjects

// MARK: - Fixture plumbing
//
// Real keys through `AgeKeyPair.generate()` and real scratch project roots
// through `applierScratchDirectory(_:)` — both already exist in
// `ProjectRecipientApplierTests.swift` (same test target), reused rather
// than redeclared, same discipline `CreationPlanResolverTests` follows.

@Suite("SopsConfigGenerator — a proposal sops itself has already confirmed")
struct SopsConfigGeneratorTests {

    /// The real test named in the brief: not just that this type's own
    /// `verified` flag says yes, but that a second, independent type —
    /// `CreationPlanResolver`, going through the bridge a second time —
    /// agrees when the proposed text is actually written as a `.sops.yaml`.
    @Test("a nested target with two recipients verifies, and CreationPlanResolver independently agrees")
    func nestedTargetVerifiesAndResolverAgrees() throws {
        let first = try AgeKeyPair.generate()
        let second = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("config-generator-nested")
        let target = root.appendingPathComponent("secrets/prod.yaml")

        let proposed = try SopsConfigGenerator.propose(
            forTarget: target, in: root, recipients: [first.public, second.public])

        #expect(proposed.verified)
        #expect(proposed.reason.isEmpty)
        #expect(!proposed.text.isEmpty)

        try proposed.text.write(
            to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let plan = try CreationPlanResolver.plan(forTarget: target, in: root)
        guard case .governedByRule(let recipients, let encryptedRegex) = plan else {
            Issue.record("expected .governedByRule, got \(plan)")
            return
        }
        #expect(Set(recipients) == Set([first.public, second.public]))
        #expect(encryptedRegex.isEmpty)
    }

    @Test("a root-level target (no directory) also verifies")
    func rootLevelTargetVerifies() throws {
        let key = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("config-generator-root")
        let target = root.appendingPathComponent("prod.yaml")

        let proposed = try SopsConfigGenerator.propose(
            forTarget: target, in: root, recipients: [key.public])

        #expect(proposed.verified)
        #expect(proposed.reason.isEmpty)
        #expect(proposed.text.contains("prod\\.yaml"))

        try proposed.text.write(
            to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let plan = try CreationPlanResolver.plan(forTarget: target, in: root)
        #expect(plan == .governedByRule(recipients: [key.public], encryptedRegex: ""))
    }

    @Test("no probe file survives a successful proposal")
    func noProbeFileSurvivesSuccess() throws {
        let key = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("config-generator-cleanup-ok")
        let target = root.appendingPathComponent("secrets/prod.yaml")

        let proposed = try SopsConfigGenerator.propose(
            forTarget: target, in: root, recipients: [key.public])
        #expect(proposed.verified)

        #expect(try Self.probeLeftovers(in: root).isEmpty)
    }

    /// An invalid age recipient makes sops's own config parser fail to load
    /// the staged probe — `lookupCreationRule` throws — which is exactly the
    /// path whose cleanup the brief calls out by name: the probe must not
    /// survive the bridge throwing, not just the happy path.
    @Test("no probe file survives when the bridge refuses an invalid recipient, and the refusal is reported")
    func noProbeFileSurvivesBridgeFailure() throws {
        let root = try applierScratchDirectory("config-generator-cleanup-fail")
        let target = root.appendingPathComponent("secrets/prod.yaml")

        let proposed = try SopsConfigGenerator.propose(
            forTarget: target, in: root, recipients: ["not-a-valid-age-recipient"])

        #expect(!proposed.verified)
        #expect(!proposed.reason.isEmpty)
        #expect(proposed.text.isEmpty)

        #expect(try Self.probeLeftovers(in: root).isEmpty)
    }

    /// The deliberate case the task's self-review calls for: a same-length
    /// sibling filename that differs only where the target's own "." sits.
    /// An unescaped "." in `path_regex` matches any character, so it would
    /// wrongly govern this file too — exactly the "which files a rule
    /// governs is who can read them" hazard this type's doc comment names.
    @Test("path_regex escapes the dot, so a same-length sibling with a different character is not matched")
    func dotIsEscapedNotWildcard() throws {
        let key = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("config-generator-dot-escape")
        let target = root.appendingPathComponent("secrets/prod.yaml")

        let proposed = try SopsConfigGenerator.propose(
            forTarget: target, in: root, recipients: [key.public])
        #expect(proposed.verified)

        let configURL = root.appendingPathComponent(".sops.yaml")
        try proposed.text.write(to: configURL, atomically: true, encoding: .utf8)

        // Same length as "prod.yaml", the "." swapped for another character.
        let sibling = root.appendingPathComponent("secrets/prodXyaml")
        let lookup = try SopsBridge.lookupCreationRule(
            configPath: configURL.path, targetFilePath: sibling.path)
        #expect(!lookup.matched, "an unescaped '.' would have matched this same-length sibling")
    }

    // MARK: - Absolute-path enforcement (same discipline as CreationPlanResolver/SecretFileCreator)

    @Test("a relative target is refused before anything is staged")
    func relativeTargetIsRefused() throws {
        let root = try applierScratchDirectory("config-generator-relative-target")

        // A URL whose `.path` is relative, not one merely built with a
        // relative-looking string — `URL(fileURLWithPath:)` resolves
        // against the process's current directory and would already be
        // absolute.
        let target = URL(string: "secrets/prod.yaml")!
        #expect(!target.path.hasPrefix("/"))

        #expect(throws: SopsConfigGenerator.Error.targetNotAbsolute(target.path)) {
            try SopsConfigGenerator.propose(forTarget: target, in: root, recipients: ["age1anything"])
        }
        #expect(try Self.probeLeftovers(in: root).isEmpty)
    }

    @Test("a relative project root is refused before anything is staged")
    func relativeProjectRootIsRefused() throws {
        let root = URL(string: "some/relative/project")!
        #expect(!root.path.hasPrefix("/"))

        let target = URL(fileURLWithPath: "/tmp/config-generator-unused/secrets/prod.yaml")

        #expect(throws: SopsConfigGenerator.Error.projectRootNotAbsolute(root.path)) {
            try SopsConfigGenerator.propose(forTarget: target, in: root, recipients: ["age1anything"])
        }
    }

    @Test("a target outside the project root is refused before anything is staged")
    func targetOutsideProjectRootIsRefused() throws {
        let root = try applierScratchDirectory("config-generator-outside")
        let target = URL(fileURLWithPath: "/tmp/config-generator-elsewhere/secrets/prod.yaml")

        #expect(throws: SopsConfigGenerator.Error.targetOutsideProjectRoot(target.path)) {
            try SopsConfigGenerator.propose(forTarget: target, in: root, recipients: ["age1anything"])
        }
        #expect(try Self.probeLeftovers(in: root).isEmpty)
    }

    /// A project root that has never been created (or was deleted) makes
    /// "inside `projectRoot`" a claim nothing can honestly check — see
    /// `requireProjectRootExists`'s doc comment. This also pins the Minor
    /// review finding: the reason names the actual problem rather than
    /// falling through to the generic "could not be staged" catch-all,
    /// which it would if this check did not exist.
    @Test("a project root that does not exist is refused, and the reason names it")
    func nonExistentProjectRootIsRefused() throws {
        let parent = try applierScratchDirectory("config-generator-missing-root-parent")
        let root = parent.appendingPathComponent("never-created", isDirectory: true)
        let target = root.appendingPathComponent("secrets/prod.yaml")

        #expect(throws: SopsConfigGenerator.Error.projectRootDoesNotExist(root.path)) {
            try SopsConfigGenerator.propose(forTarget: target, in: root, recipients: ["age1anything"])
        }
    }

    /// A project root that exists as a plain file, not a directory, must be
    /// refused the same way — `isDirectory` is checked, not merely
    /// existence.
    @Test("a project root that is a file, not a directory, is refused")
    func fileProjectRootIsRefused() throws {
        let parent = try applierScratchDirectory("config-generator-file-root-parent")
        let root = parent.appendingPathComponent("not-a-directory")
        try "not a directory".write(to: root, atomically: true, encoding: .utf8)
        let target = root.appendingPathComponent("secrets/prod.yaml")

        #expect(throws: SopsConfigGenerator.Error.projectRootDoesNotExist(root.path)) {
            try SopsConfigGenerator.propose(forTarget: target, in: root, recipients: ["age1anything"])
        }
    }

    /// The reviewer's concrete escape: a target whose literal path shares
    /// `root`'s string prefix (so the plain prefix check in `relativePath`
    /// alone would call it "inside") but that walks back out via `..`
    /// components. Refused *before* anything is staged, and before
    /// `path_regex` is ever derived from it — see this type's doc comment,
    /// "Containment is enforced here, independently of `SecretFileCreator`",
    /// for why this app cannot rely on `SecretFileCreator`'s own `..`
    /// refusal to cover a `.sops.yaml` this type proposes, which
    /// `SecretFileCreator` never opens.
    @Test("a target containing a literal .. component is refused, even though it shares the root's string prefix")
    func dotDotComponentIsRefused() throws {
        let root = try applierScratchDirectory("config-generator-dotdot")
        let target = root.appendingPathComponent("secrets/../../../../tmp/config-generator-dotdot-evil.yaml")
        #expect(target.path.hasPrefix(root.path), "sanity: the literal string prefix check alone would pass this")

        #expect(throws: SopsConfigGenerator.Error.targetOutsideProjectRoot(target.path)) {
            try SopsConfigGenerator.propose(forTarget: target, in: root, recipients: ["age1anything"])
        }
        #expect(try Self.probeLeftovers(in: root).isEmpty)
    }

    /// Cheap extra coverage past the dot: other regex metacharacters in a
    /// target's own name must also be escaped, or the staged probe either
    /// fails to compile as a regex or matches something other than what was
    /// asked for — either way `verified` would come back `false`, so a
    /// passing `verified == true` here is itself the proof.
    @Test("path_regex escapes other regex metacharacters too, not only the dot")
    func otherMetacharactersAreEscaped() throws {
        let key = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("config-generator-other-metachars")
        let target = root.appendingPathComponent("secrets/a+b(c)[d]$e.yaml")

        let proposed = try SopsConfigGenerator.propose(
            forTarget: target, in: root, recipients: [key.public])

        #expect(
            proposed.verified,
            """
            sops itself failed to match a target whose name contains regex metacharacters — one of them \
            was left unescaped: \(proposed.reason)
            """)
    }

    // MARK: - Helpers

    private static func probeLeftovers(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".sops.yaml.") && $0.hasSuffix(".tmp") }
    }
}
