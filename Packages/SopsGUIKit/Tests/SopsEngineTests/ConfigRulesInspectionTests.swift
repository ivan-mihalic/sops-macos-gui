import Foundation
import ScratchCleanup
import Testing

@testable import SopsEngine

/// SOPS-39: `SopsBridge.inspectConfigRules` is the whole-config, read-only
/// view the Access page renders — named keys (YAML anchors), every creation
/// rule with its age recipients resolved through aliases, and which rule
/// governs each candidate path. See `Engine/gobridge/configrules.go` for the
/// Go side this decodes.
@Suite("SopsBridge config rules inspection")
struct ConfigRulesInspectionTests {
    @Test("named keys and aliased rule recipients come back with their anchor names")
    func anchorsAreNamed() throws {
        let root = try ScratchDirectoryRegistry.shared.makeDirectory("config-rules")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try AgeKeyPair.generate().public
        let b = try AgeKeyPair.generate().public
        let conf = root.appendingPathComponent(".sops.yaml")
        try """
            keys:
              - &studio \(a)
              - &laptop \(b)
            creation_rules:
              - path_regex: prod\\.env$
                key_groups:
                  - age: [*studio, *laptop]
              - path_regex: .*
                age: \(a)

            """.write(to: conf, atomically: true, encoding: .utf8)
        let prod = root.appendingPathComponent("prod.env").path
        let rules = try SopsBridge.inspectConfigRules(configPath: conf.path, candidateFilePaths: [prod])
        #expect(rules.keys.map(\.name) == ["studio", "laptop"])
        #expect(rules.rules[0].recipients.map(\.name) == ["studio", "laptop"])
        #expect(rules.rules[0].usesAnchors && rules.rules[0].usesKeyGroups)
        #expect(rules.rules[1].recipients == [.init(name: "", recipient: a)])
        #expect(rules.governedBy[prod] == 0)
    }

    /// The write half of SOPS-39 task 9, proved by the read half: an alias
    /// added to an anchored rule has to come back out of `inspectConfigRules`
    /// under the *name* it was added by, or the Access page cannot show it.
    @Test("adding an alias to an anchored rule shows up in inspection with its name")
    func aliasAdditionIsVisible() throws {
        let root = try ScratchDirectoryRegistry.shared.makeDirectory("config-alias")
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = try AgeKeyPair.generate().public
        let laptop = try AgeKeyPair.generate().public
        let conf = root.appendingPathComponent(".sops.yaml")
        try """
            keys:
              - &studio \(studio)
              - &laptop \(laptop)
            creation_rules:
              # production
              - path_regex: prod\\.env$
                key_groups:
                  - age: [*studio]
              - path_regex: .*
                age:
                  - \(studio)

            """.write(to: conf, atomically: true, encoding: .utf8)

        let text = try SopsBridge.addAliasRecipient(
            configPath: conf.path, ruleIndex: 1, anchor: "laptop")
        // Nothing was written by the bridge — the caller writes, always.
        #expect(try String(contentsOf: conf, encoding: .utf8).contains("*laptop") == false)
        try text.write(to: conf, atomically: true, encoding: .utf8)

        let rules = try SopsBridge.inspectConfigRules(
            configPath: conf.path, candidateFilePaths: [])
        #expect(rules.rules[1].recipients.map(\.name) == ["", "laptop"])
        #expect(rules.rules[1].recipients.map(\.recipient) == [studio, laptop])
        // The rule that was not touched, and the comment above it, are intact.
        #expect(rules.rules[0].recipients.map(\.name) == ["studio"])
        #expect(rules.rules[0].comment == "production")
    }

    @Test("the bridge refuses an unknown anchor, a duplicate and an out-of-range rule")
    func aliasAdditionRefusals() throws {
        let root = try ScratchDirectoryRegistry.shared.makeDirectory("config-alias-refuse")
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = try AgeKeyPair.generate().public
        let conf = root.appendingPathComponent(".sops.yaml")
        try """
            keys:
              - &studio \(studio)
            creation_rules:
              - path_regex: .*
                age: [*studio]

            """.write(to: conf, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try SopsBridge.addAliasRecipient(configPath: conf.path, ruleIndex: 0, anchor: "nobody")
        }
        #expect(throws: (any Error).self) {
            try SopsBridge.addAliasRecipient(configPath: conf.path, ruleIndex: 0, anchor: "studio")
        }
        #expect(throws: (any Error).self) {
            try SopsBridge.addAliasRecipient(configPath: conf.path, ruleIndex: 9, anchor: "studio")
        }
    }
}
