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

        // SOPS-39 task 10. `throws: (any Error).self` was true of all three
        // and told them apart from nothing — a bridge that refused every
        // call with one message would have passed. What each refusal *says*
        // is the contract: it names the anchor or the rule, never a value,
        // and `ProjectRecipientApplier.addAliasToRule` shows that sentence
        // to the user verbatim.
        for (ruleIndex, anchor, expected) in [
            (0, "nobody", "no key named \"nobody\""),
            (0, "studio", "already names \"studio\""),
            (9, "studio", "creation rule 9"),
        ] {
            var sentence = ""
            do {
                _ = try SopsBridge.addAliasRecipient(
                    configPath: conf.path, ruleIndex: ruleIndex, anchor: anchor)
                Issue.record("adding \(anchor) to rule \(ruleIndex) must be refused")
                continue
            } catch {
                sentence = String(describing: error)
            }
            #expect(sentence.contains(expected),
                    "refusal for (\(ruleIndex), \(anchor)) read: \(sentence)")
            // And never the key material itself, which the config holds
            // right next to the anchor being refused.
            #expect(!sentence.contains(studio), "a refusal must not quote a key")
        }
    }

    // MARK: - SOPS-42: removing an alias, declaring a new named key

    @Test("removing an alias from an anchored rule disappears from inspection")
    func aliasRemovalIsVisible() throws {
        let root = try ScratchDirectoryRegistry.shared.makeDirectory("config-alias-remove")
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
                age:
                  - *studio
                  - *laptop

            """.write(to: conf, atomically: true, encoding: .utf8)

        let text = try SopsBridge.removeAliasRecipient(configPath: conf.path, ruleIndex: 0, anchor: "laptop")
        #expect(try String(contentsOf: conf, encoding: .utf8).contains("*laptop"), "the bridge never writes")
        try text.write(to: conf, atomically: true, encoding: .utf8)

        let rules = try SopsBridge.inspectConfigRules(configPath: conf.path, candidateFilePaths: [])
        #expect(rules.rules[0].recipients.map(\.name) == ["studio"])
        #expect(rules.keys.map(\.name) == ["studio", "laptop"], "keys: keeps the declaration")
        #expect(rules.rules[0].comment == "production")
    }

    @Test("the bridge refuses removing the last recipient and an absent alias, naming no key")
    func aliasRemovalRefusals() throws {
        let root = try ScratchDirectoryRegistry.shared.makeDirectory("config-alias-remove-refuse")
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = try AgeKeyPair.generate().public
        let laptop = try AgeKeyPair.generate().public
        let conf = root.appendingPathComponent(".sops.yaml")
        try """
            keys:
              - &studio \(studio)
              - &laptop \(laptop)
            creation_rules:
              - path_regex: prod\\.env$
                age:
                  - *studio

            """.write(to: conf, atomically: true, encoding: .utf8)
        for (anchor, expected) in [("studio", "no age recipient"), ("laptop", "does not name \"laptop\""), ("nobody", "no key named")] {
            var sentence = ""
            do {
                _ = try SopsBridge.removeAliasRecipient(configPath: conf.path, ruleIndex: 0, anchor: anchor)
                Issue.record("removing \(anchor) must be refused")
                continue
            } catch {
                sentence = String(describing: error)
            }
            #expect(sentence.contains(expected), "refusal for \(anchor) read: \(sentence)")
            #expect(!sentence.contains(studio) && !sentence.contains(laptop), "a refusal must not quote a key")
        }
    }

    @Test("adding a named key declares it and aliases it in one text")
    func namedKeyAdditionIsVisible() throws {
        let root = try ScratchDirectoryRegistry.shared.makeDirectory("config-named-key")
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = try AgeKeyPair.generate().public
        let deploy = try AgeKeyPair.generate().public
        let conf = root.appendingPathComponent(".sops.yaml")
        try """
            keys:
              - &studio \(studio)
            creation_rules:
              - path_regex: prod\\.env$
                age:
                  - *studio

            """.write(to: conf, atomically: true, encoding: .utf8)

        let text = try SopsBridge.addNamedKey(configPath: conf.path, name: "deploy", recipient: deploy, ruleIndex: 0)
        #expect(!(try String(contentsOf: conf, encoding: .utf8)).contains("deploy"), "the bridge never writes")
        try text.write(to: conf, atomically: true, encoding: .utf8)

        let rules = try SopsBridge.inspectConfigRules(configPath: conf.path, candidateFilePaths: [])
        #expect(rules.keys.map(\.name) == ["studio", "deploy"])
        #expect(rules.keys.map(\.recipient) == [studio, deploy])
        #expect(rules.rules[0].recipients.map(\.name) == ["studio", "deploy"])
    }

    @Test("the bridge refuses a taken anchor, a private identity and a key keys: already declares")
    func namedKeyRefusals() throws {
        let root = try ScratchDirectoryRegistry.shared.makeDirectory("config-named-key-refuse")
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = try AgeKeyPair.generate()
        let deploy = try AgeKeyPair.generate()
        let conf = root.appendingPathComponent(".sops.yaml")
        try """
            keys:
              - &studio \(studio.public)
            creation_rules:
              - path_regex: prod\\.env$
                age: [*studio]

            """.write(to: conf, atomically: true, encoding: .utf8)
        for (name, recipient, expected) in [
            ("studio", deploy.public, "already declares a key named \"studio\""),
            ("deploy", deploy.private, "not usable"),
            ("deploy", studio.public, "already declares that key as \"studio\""),
            ("two words", deploy.public, "anchor"),
        ] {
            var sentence = ""
            do {
                _ = try SopsBridge.addNamedKey(configPath: conf.path, name: name, recipient: recipient, ruleIndex: 0)
                Issue.record("\(name) must be refused")
                continue
            } catch {
                sentence = String(describing: error)
            }
            #expect(sentence.contains(expected), "refusal for \(name) read: \(sentence)")
            #expect(!sentence.contains(studio.public) && !sentence.contains(deploy.public)
                    && !sentence.contains(deploy.private), "a refusal must not quote a key")
        }
    }
}
