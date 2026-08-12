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

    /// This is also the proof that a project with no config never asks the
    /// bridge anything: if it had, sops would have been handed a config path
    /// that does not exist and this would come back `.configUnreadable`, not
    /// `.noConfig` — the two are only distinguishable if the no-config branch
    /// truly returns before the bridge is called.
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
}
