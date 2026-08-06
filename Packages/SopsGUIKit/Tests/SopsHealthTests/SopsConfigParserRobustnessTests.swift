import Foundation
import Testing
@testable import SopsHealth

private let key1 = "age1ykd0u99qxpdl4yr57lwqv5rt9e473p6hhdps2a5q5ddmt0x6ryaqkjpx4f"
private let key2 = "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"

/// Inputs a real user is plausibly going to hand this parser, beyond the
/// narrow shape the brief's own tests exercise. See the doc comment on
/// `SopsConfig` in ProjectHealthCheck.swift for the design decision this
/// file is proving: handle what's unambiguous, refuse (return nil) rather
/// than guess at what isn't.
@Suite("SopsConfig parser robustness")
struct SopsConfigParserRobustnessTests {

    @Test("full-line and trailing comments are ignored")
    func comments() throws {
        let text = """
        # top-level comment
        creation_rules:
          # a comment before a rule
          - path_regex: secrets/.*\\.yaml$  # trailing comment
            age: \(key1),\(key2) # another trailing comment
        """
        let config = try #require(SopsConfig(parsing: text))
        #expect(config.creationRules.count == 1)
        #expect(config.creationRules[0].pathRegex == "secrets/.*\\.yaml$")
        #expect(config.creationRules[0].ageRecipients == [key1, key2])
    }

    @Test("age as a block YAML list parses the same as a comma-joined string")
    func ageAsBlockList() throws {
        let text = """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            age:
              - \(key1)
              - \(key2)
        """
        let config = try #require(SopsConfig(parsing: text))
        #expect(config.creationRules[0].ageRecipients == [key1, key2])
    }

    @Test("age as a single-line YAML flow sequence parses correctly, not into keys with stray brackets")
    func ageAsFlowSequence() throws {
        let text = """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            age: [\(key1), \(key2)]
        """
        let config = try #require(SopsConfig(parsing: text))
        #expect(config.creationRules[0].ageRecipients == [key1, key2])
        // The specific regression: neither recipient carries a stray `[`/`]`.
        for recipient in config.creationRules[0].ageRecipients {
            #expect(!recipient.contains("["))
            #expect(!recipient.contains("]"))
        }
    }

    @Test("a flow sequence with internal spacing around commas still parses cleanly")
    func ageAsFlowSequenceWithSpacing() throws {
        let text = "creation_rules:\n  - path_regex: secrets/.*\\.yaml$\n    age: [ \(key1) , \(key2) ]\n"
        let config = try #require(SopsConfig(parsing: text))
        #expect(config.creationRules[0].ageRecipients == [key1, key2])
    }

    @Test("an empty flow sequence, age: [], means zero recipients, not a parse failure")
    func ageAsEmptyFlowSequence() throws {
        let text = "creation_rules:\n  - path_regex: secrets/.*\\.yaml$\n    age: []\n"
        let config = try #require(SopsConfig(parsing: text))
        #expect(config.creationRules[0].ageRecipients.isEmpty)
    }

    @Test("an unclosed age flow sequence is refused, not half-parsed into a garbage recipient")
    func unclosedAgeFlowSequenceIsRefused() {
        let text = "creation_rules:\n  - path_regex: secrets/.*\\.yaml$\n    age: [\(key1), \(key2)\n"
        #expect(SopsConfig(parsing: text) == nil)
    }

    @Test("of multiple creation rules, the first whose path_regex matches wins, even if it's not the first rule")
    func laterRuleMatches() throws {
        let text = """
        creation_rules:
          - path_regex: nomatch/.*
            age: \(key1)
          - path_regex: secrets/.*\\.yaml$
            age: \(key2)
        """
        let config = try #require(SopsConfig(parsing: text))
        #expect(config.creationRules.count == 2)
        let rule = config.rule(matching: "secrets/prod.yaml")
        #expect(rule?.ageRecipients == [key2])
    }

    @Test("quoted path_regex and age values are unquoted")
    func quotedValues() throws {
        let text = """
        creation_rules:
          - path_regex: "secrets/.*\\.yaml$"
            age: "\(key1)","\(key2)"
        """
        let config = try #require(SopsConfig(parsing: text))
        #expect(config.creationRules[0].pathRegex == "secrets/.*\\.yaml$")
        #expect(config.creationRules[0].ageRecipients == [key1, key2])
    }

    @Test("single-quoted values are unquoted too")
    func singleQuotedValues() throws {
        let text = "creation_rules:\n  - path_regex: 'secrets/.*\\.yaml$'\n    age: '\(key1)'\n"
        let config = try #require(SopsConfig(parsing: text))
        #expect(config.creationRules[0].pathRegex == "secrets/.*\\.yaml$")
        #expect(config.creationRules[0].ageRecipients == [key1])
    }

    @Test("CRLF line endings parse the same as LF")
    func crlf() throws {
        let lfText = """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            age: \(key1),\(key2)
        """
        let crlfText = lfText.replacingOccurrences(of: "\n", with: "\r\n")
        let config = try #require(SopsConfig(parsing: crlfText))
        #expect(config.creationRules[0].pathRegex == "secrets/.*\\.yaml$")
        #expect(config.creationRules[0].ageRecipients == [key1, key2])
    }

    @Test("a rule with no path_regex matches every file, and only after earlier rules are checked")
    func catchAllRuleIsLast() throws {
        let text = """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            age: \(key1)
          - age: \(key2)
        """
        let config = try #require(SopsConfig(parsing: text))
        #expect(config.rule(matching: "secrets/prod.yaml")?.ageRecipients == [key1])
        #expect(config.rule(matching: "elsewhere/other.yaml")?.ageRecipients == [key2])
    }

    @Test("unbalanced flow-YAML brackets are refused rather than guessed at")
    func unbalancedBracketsAreRefused() {
        let text = "creation_rules:\n  - this: [is: not: valid\n"
        #expect(SopsConfig(parsing: text) == nil)
    }

    @Test("a file with no creation_rules key at all is refused, not silently treated as zero rules")
    func noCreationRulesKey() {
        let text = "stores:\n  - foo: bar\n"
        #expect(SopsConfig(parsing: text) == nil)
    }
}
