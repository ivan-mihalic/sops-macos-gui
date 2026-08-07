import Foundation
import Testing

@testable import SopsEngine

@Suite("SopsBridge.lookupCreationRule")
struct CreationRuleLookupTests {

    @Test("a matching rule returns its age recipients")
    func matchingRule() throws {
        let key = try AgeKeyPair.generate()
        let dir = try TempFile(named: ".sops.yaml", contents: """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            age: \(key.public)
        """)
        let confPath = dir.path
        let target = (confPath as NSString).deletingLastPathComponent + "/secrets/prod.yaml"

        let lookup = try SopsBridge.lookupCreationRule(configPath: confPath, targetFilePath: target)

        #expect(lookup.matched)
        #expect(lookup.ageRecipients == [key.public])
        #expect(lookup.nonAgeBackends.isEmpty)
    }

    @Test("no matching rule is not an error")
    func noMatch() throws {
        let key = try AgeKeyPair.generate()
        let dir = try TempFile(named: ".sops.yaml", contents: """
        creation_rules:
          - path_regex: nomatch/.*
            age: \(key.public)
        """)
        let confPath = dir.path
        let target = (confPath as NSString).deletingLastPathComponent + "/secrets/prod.yaml"

        let lookup = try SopsBridge.lookupCreationRule(configPath: confPath, targetFilePath: target)

        #expect(!lookup.matched)
        #expect(lookup.ageRecipients.isEmpty)
    }

    @Test("a malformed config throws with sops's own error text")
    func malformed() throws {
        let dir = try TempFile(named: ".sops.yaml", contents: "creation_rules:\n  - this: [is: not: valid\n")
        let confPath = dir.path
        let target = (confPath as NSString).deletingLastPathComponent + "/secrets/prod.yaml"

        #expect(throws: SopsBridgeError.self) {
            try SopsBridge.lookupCreationRule(configPath: confPath, targetFilePath: target)
        }
    }

    @Test("a pgp-only rule reports the pgp backend and no age recipients")
    func pgpOnly() throws {
        let dir = try TempFile(named: ".sops.yaml", contents: """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            pgp: 0000000000000000000000000000000000AAAA
        """)
        let confPath = dir.path
        let target = (confPath as NSString).deletingLastPathComponent + "/secrets/prod.yaml"

        let lookup = try SopsBridge.lookupCreationRule(configPath: confPath, targetFilePath: target)

        #expect(lookup.matched)
        #expect(lookup.ageRecipients.isEmpty)
        #expect(lookup.nonAgeBackends == ["pgp"])
    }

    @Test("a multi-line flow sequence age list parses correctly, end to end through the bridge")
    func multiLineFlowSequence() throws {
        let key1 = try AgeKeyPair.generate()
        let key2 = try AgeKeyPair.generate()
        let dir = try TempFile(named: ".sops.yaml", contents: """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            age: [\(key1.public),
                  \(key2.public)]
        """)
        let confPath = dir.path
        let target = (confPath as NSString).deletingLastPathComponent + "/secrets/prod.yaml"

        let lookup = try SopsBridge.lookupCreationRule(configPath: confPath, targetFilePath: target)

        #expect(lookup.matched)
        #expect(Set(lookup.ageRecipients) == Set([key1.public, key2.public]))
    }
}
