import Foundation
import ScratchCleanup
import Testing

@testable import SopsProjects

// MARK: - Fixture plumbing
//
// Real temporary `.sops.yaml` fixtures through the real bridge, never a
// constructed `CreationRuleLookup` — same discipline `ProjectRecipientApplierTests`
// uses. `AgeKeyPair.generate()` and `applierScratchDirectory(_:)` already exist
// there (same test target), so they are reused rather than redeclared.

@Suite("CreationPlanResolver")
struct CreationPlanResolverTests {

    @Test("an age-only rule whose path_regex reaches the target governs it")
    func governedByAgeOnlyRule() throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("creation-plan")
        try """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(owner.public)
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let target = root.appendingPathComponent("secrets/prod.yaml")

        let plan = try CreationPlanResolver.plan(forTarget: target, in: root)

        #expect(plan == .governedByRule(recipients: [owner.public], encryptedRegex: ""))
    }

    @Test("the same rule does not govern a target outside its path_regex")
    func noRuleMatchedOutsideRegex() throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("creation-plan")
        try """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(owner.public)
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let target = root.appendingPathComponent("public/notes.yaml")

        let plan = try CreationPlanResolver.plan(forTarget: target, in: root)

        #expect(plan == .noRuleMatched)
    }

    /// This is also indirect evidence that a project with no config never
    /// asks the bridge anything: if it had, sops would have been handed a
    /// config path that does not exist and this would come back
    /// `.configUnreadable`, not `.noConfig`. Not a call-count assertion —
    /// there is no seam here to count calls through — just the fact that the
    /// two results are only distinguishable if the no-config branch truly
    /// returns before the bridge is called.
    @Test("a project with no .sops.yaml resolves to .noConfig")
    func noConfigWithoutCallingTheBridge() throws {
        let root = try applierScratchDirectory("creation-plan")
        let target = root.appendingPathComponent("secrets/prod.yaml")

        let plan = try CreationPlanResolver.plan(forTarget: target, in: root)

        #expect(plan == .noConfig)
    }

    @Test("a malformed .sops.yaml is reported with sops's own error text")
    func configUnreadableCarriesBridgeText() throws {
        let root = try applierScratchDirectory("creation-plan")
        try "creation_rules:\n  - this: [is: not: valid\n"
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let target = root.appendingPathComponent("secrets/prod.yaml")

        let plan = try CreationPlanResolver.plan(forTarget: target, in: root)

        guard case .configUnreadable(let reason) = plan else {
            Issue.record("expected .configUnreadable, got \(plan)")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("a rule naming a pgp recipient is refused, and the reason names the backend")
    func unsupportedBackendNamesIt() throws {
        let root = try applierScratchDirectory("creation-plan")
        try """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                pgp: 0000000000000000000000000000000000AAAA
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let target = root.appendingPathComponent("secrets/prod.yaml")

        let plan = try CreationPlanResolver.plan(forTarget: target, in: root)

        guard case .unsupportedRule(let reason) = plan else {
            Issue.record("expected .unsupportedRule, got \(plan)")
            return
        }
        #expect(reason.contains("pgp"))
    }

    @Test("a rule with unencrypted_suffix is refused, and the reason names the field")
    func unsupportedScopingFieldNamesIt() throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("creation-plan")
        try """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(owner.public)
                unencrypted_suffix: "_plain"
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let target = root.appendingPathComponent("secrets/prod.yaml")

        let plan = try CreationPlanResolver.plan(forTarget: target, in: root)

        guard case .unsupportedRule(let reason) = plan else {
            Issue.record("expected .unsupportedRule, got \(plan)")
            return
        }
        #expect(reason.contains("unencrypted_suffix"))
    }

    @Test("a rule with unencrypted_regex is refused, and the reason names the field")
    func unsupportedUnencryptedRegexNamesIt() throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("creation-plan")
        try """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(owner.public)
                unencrypted_regex: '^metadata$'
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let target = root.appendingPathComponent("secrets/prod.yaml")

        let plan = try CreationPlanResolver.plan(forTarget: target, in: root)

        guard case .unsupportedRule(let reason) = plan else {
            Issue.record("expected .unsupportedRule, got \(plan)")
            return
        }
        #expect(reason.contains("unencrypted_regex"))
    }

    @Test("a rule with encrypted_suffix is refused, and the reason names the field")
    func unsupportedEncryptedSuffixNamesIt() throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("creation-plan")
        try """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(owner.public)
                encrypted_suffix: "_secret"
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let target = root.appendingPathComponent("secrets/prod.yaml")

        let plan = try CreationPlanResolver.plan(forTarget: target, in: root)

        guard case .unsupportedRule(let reason) = plan else {
            Issue.record("expected .unsupportedRule, got \(plan)")
            return
        }
        #expect(reason.contains("encrypted_suffix"))
    }

    @Test("encrypted_regex is not a refusal — governedByRule passes it through")
    func encryptedRegexPassesThrough() throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("creation-plan")
        try """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(owner.public)
                encrypted_regex: '^(data|stringData)$'
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let target = root.appendingPathComponent("secrets/prod.yaml")

        let plan = try CreationPlanResolver.plan(forTarget: target, in: root)

        #expect(plan == .governedByRule(recipients: [owner.public], encryptedRegex: "^(data|stringData)$"))
    }

    /// Pins the decision order (brief step 4 before step 5): a rule that sets
    /// both a non-age backend and an unsupported scoping field must be
    /// refused for the backend, never for the field. A resolver whose checks
    /// ran in the opposite order would still refuse here, but for the wrong
    /// reason — and a user reading "this rule sets unencrypted_suffix" would
    /// have no idea half the team cannot read the file at all.
    @Test("a rule with both a non-age backend and an unsupported scoping field is refused for the backend")
    func backendReasonWinsOverScopingField() throws {
        let root = try applierScratchDirectory("creation-plan")
        try """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                pgp: 0000000000000000000000000000000000AAAA
                unencrypted_suffix: "_plain"
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let target = root.appendingPathComponent("secrets/prod.yaml")

        let plan = try CreationPlanResolver.plan(forTarget: target, in: root)

        guard case .unsupportedRule(let reason) = plan else {
            Issue.record("expected .unsupportedRule, got \(plan)")
            return
        }
        #expect(reason.contains("pgp"))
        #expect(!reason.contains("unencrypted_suffix"))
    }

    // MARK: - The absolute-path contract

    /// `SopsBridge.lookupCreationRule` matches `path_regex` against the
    /// target relative to the config's own directory, computed by stripping
    /// that directory as a literal prefix — a relative target silently fails
    /// to strip, so a caller's bug there does not surface as an error at
    /// all, it just matches every rule against the wrong string (see
    /// `Engine/gobridge/config.go`'s `filepath.Abs`, which joins a relative
    /// path onto the Go process's own working directory rather than
    /// rejecting it). This is the resolver refusing that bug before it can
    /// happen, rather than relying on the bridge to catch it.
    @Test("a relative target is refused before the bridge is ever asked")
    func relativeTargetIsRefused() throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("creation-plan")
        try """
            creation_rules:
              - path_regex: .*
                age: \(owner.public)
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        // A URL whose `.path` is relative, not one merely built with a
        // relative-looking string — `URL(fileURLWithPath:)` resolves against
        // the process's current directory and would already be absolute.
        let target = URL(string: "secrets/prod.yaml")!
        #expect(!target.path.hasPrefix("/"))

        #expect(throws: CreationPlanResolver.Error.targetNotAbsolute(target.path)) {
            try CreationPlanResolver.plan(forTarget: target, in: root)
        }
    }

    @Test("a relative project root is refused before the bridge is ever asked")
    func relativeProjectRootIsRefused() throws {
        let root = URL(string: "some/relative/project")!
        #expect(!root.path.hasPrefix("/"))

        // Absolute and otherwise unremarkable — deliberately not built off
        // `root`, so this isolates the project-root check: were `target`
        // also relative, a resolver that checks `target` first would throw
        // `.targetNotAbsolute` here instead, and this test would not be
        // pinning what it claims to.
        let target = URL(fileURLWithPath: "/tmp/creation-plan-unused/secrets/prod.yaml")

        #expect(throws: CreationPlanResolver.Error.projectRootNotAbsolute(root.path)) {
            try CreationPlanResolver.plan(forTarget: target, in: root)
        }
    }

    // MARK: - Containment

    /// The concrete escape this guard exists to close, measured against the
    /// real bridge rather than assumed: without the containment check,
    /// `target` — absolute, but nowhere near `root` — reaches
    /// `SopsBridge.lookupCreationRule` unchanged. `Engine/gobridge/config.go`'s
    /// `LookupCreationRule` strips `root`'s path as a *literal* prefix
    /// (`strings.TrimPrefix`), which is a no-op here since `target` does not
    /// share it, leaving `target`'s full absolute path to be matched against
    /// `path_regex` **unanchored** — and `secrets/.*\.yaml$` matches
    /// `/…/elsewhere/secrets/prod.yaml` as a substring. Without this guard
    /// that would come back `.governedByRule` with this project's
    /// recipients, for a file this project has nothing to do with.
    @Test("a target far outside the project root is refused, not matched unanchored")
    func targetOutsideProjectRootIsRefused() throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("creation-plan-outside")
        try """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(owner.public)
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let elsewhere = try applierScratchDirectory("creation-plan-elsewhere")
        let target = elsewhere.appendingPathComponent("secrets/prod.yaml")

        #expect(throws: CreationPlanResolver.Error.targetOutsideProjectRoot(target.path)) {
            try CreationPlanResolver.plan(forTarget: target, in: root)
        }
    }

    /// The sharper version of the same escape: `target` shares `root`'s
    /// literal string prefix — so a containment check built on
    /// `hasPrefix(_:)` alone would call it "inside" — but a `..` component
    /// walks it back out. Same shape `SopsConfigGeneratorTests
    /// .dotDotComponentIsRefused` pins for `SopsConfigGenerator`; this is the
    /// identical escape one caller over.
    @Test("a target sharing the root's string prefix but escaping via .. is refused")
    func dotDotEscapeIsRefused() throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("creation-plan-dotdot")
        try """
            creation_rules:
              - path_regex: .*
                age: \(owner.public)
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let target = root.appendingPathComponent("secrets/../../evil.yaml")
        #expect(target.path.hasPrefix(root.path), "sanity: the literal prefix check alone would pass this")

        #expect(throws: CreationPlanResolver.Error.targetOutsideProjectRoot(target.path)) {
            try CreationPlanResolver.plan(forTarget: target, in: root)
        }
    }

    /// A `projectRoot` that is not there yet (or was deleted) makes "inside
    /// `projectRoot`" unprovable — the identical guard
    /// `SopsConfigGenerator.requireProjectRootExists` and
    /// `SecretFileCreator.refuseIfOutsideProject` apply, for the identical
    /// reason.
    @Test("a project root that does not exist is refused, and the bridge is never asked")
    func missingProjectRootIsRefused() throws {
        let parent = try applierScratchDirectory("creation-plan-missing-root-parent")
        let root = parent.appendingPathComponent("never-created", isDirectory: true)
        let target = root.appendingPathComponent("secrets/prod.yaml")

        #expect(throws: CreationPlanResolver.Error.projectRootDoesNotExist(root.path)) {
            try CreationPlanResolver.plan(forTarget: target, in: root)
        }
    }
}
