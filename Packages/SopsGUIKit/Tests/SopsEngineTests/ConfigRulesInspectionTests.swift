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
}
