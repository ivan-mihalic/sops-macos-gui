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

    @Test("a rule with encrypted_regex reports it and leaves the other scoping fields empty")
    func encryptedRegexIsReported() throws {
        let key = try AgeKeyPair.generate()
        let dir = try TempFile(named: ".sops.yaml", contents: """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            age: \(key.public)
            encrypted_regex: '^(data|stringData)$'
        """)
        let confPath = dir.path
        let target = (confPath as NSString).deletingLastPathComponent + "/secrets/prod.yaml"

        let lookup = try SopsBridge.lookupCreationRule(configPath: confPath, targetFilePath: target)

        #expect(lookup.matched)
        #expect(lookup.encryptedRegex == "^(data|stringData)$")
        #expect(lookup.unencryptedRegex.isEmpty)
        #expect(lookup.unencryptedSuffix.isEmpty)
        #expect(lookup.encryptedSuffix.isEmpty)
    }

    @Test("a rule with unencrypted_suffix reports it and leaves the other scoping fields empty")
    func unencryptedSuffixIsReported() throws {
        let key = try AgeKeyPair.generate()
        let dir = try TempFile(named: ".sops.yaml", contents: """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            age: \(key.public)
            unencrypted_suffix: "_plain"
        """)
        let confPath = dir.path
        let target = (confPath as NSString).deletingLastPathComponent + "/secrets/prod.yaml"

        let lookup = try SopsBridge.lookupCreationRule(configPath: confPath, targetFilePath: target)

        #expect(lookup.matched)
        #expect(lookup.unencryptedSuffix == "_plain")
        #expect(lookup.encryptedRegex.isEmpty)
        #expect(lookup.unencryptedRegex.isEmpty)
        #expect(lookup.encryptedSuffix.isEmpty)
    }

    @Test("a rule that sets none of the scoping fields reports all four as empty strings")
    func noScopingFieldsAreEmptyStrings() throws {
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
        #expect(lookup.encryptedRegex.isEmpty)
        #expect(lookup.unencryptedRegex.isEmpty)
        #expect(lookup.unencryptedSuffix.isEmpty)
        #expect(lookup.encryptedSuffix.isEmpty)
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
